const std = @import("std");
const cli = @import("cli.zig");
const diff_mod = @import("diff.zig");
const io_mod = @import("io.zig");
const report = @import("report.zig");
const server = @import("server.zig");

const PairReport = struct {
    stem: []const u8 = "",
    base_w: u32 = 0,
    base_h: u32 = 0,
    comp_w: u32 = 0,
    comp_h: u32 = 0,
    result: diff_mod.Result = .{},
    err: ?anyerror = null,
};

fn comparePair(
    persist_alloc: std.mem.Allocator,
    scratch_alloc: std.mem.Allocator,
    io: std.Io,
    path_a: []const u8,
    path_b: []const u8,
    diff_out: ?[]const u8,
    delta_path: ?[]const u8,
    cfg: *const cli.Config,
) PairReport {
    var rep = PairReport{};
    const imgs = io_mod.loadTwoImages(scratch_alloc, io, path_a, path_b) catch |e| {
        rep.err = e;
        return rep;
    };
    var base = imgs.base;
    var comp = imgs.comp;

    const opts = diff_mod.Options{
        .metric = cfg.metric,
        .threshold = cfg.threshold,
        .antialiasing = cfg.antialiasing,
        .diff_pixel = cfg.diff_pixel,
        .aa_pixel = cfg.aa_color,
        .output = if (diff_out != null) cfg.output_mode else null,
        .diff_lines = cfg.diff_lines,
        .diff_cols = cfg.diff_cols,
        .ignore_regions = cfg.ignore.items,
        .delta_dump = delta_path != null,
        .threads = cfg.threads,
    };

    var result = diff_mod.compare(&base, &comp, opts, scratch_alloc) catch |e| {
        rep.err = e;
        return rep;
    };

    if (diff_out) |p| {
        if (result.output) |out_img| {
            io_mod.savePng(scratch_alloc, io, out_img, p, cfg.png_level) catch |e| {
                rep.err = e;
                return rep;
            };
        }
    }
    if (delta_path) |p| {
        io_mod.saveDeltaBin(io, result.deltas.?, base.width, base.height, p) catch |e| {
            rep.err = e;
            return rep;
        };
    }

    if (result.lines.len > 0) {
        result.lines = persist_alloc.dupe(u32, result.lines) catch |e| {
            rep.err = e;
            return rep;
        };
    }
    if (result.cols.len > 0) {
        result.cols = persist_alloc.dupe(u32, result.cols) catch |e| {
            rep.err = e;
            return rep;
        };
    }
    result.output = null;
    result.deltas = null;

    rep.base_w = base.width;
    rep.base_h = base.height;
    rep.comp_w = comp.width;
    rep.comp_h = comp.height;
    rep.result = result;
    return rep;
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn collectPngs(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, map: *std.StringHashMap([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".png")) {
            const stem = try allocator.dupe(u8, name[0 .. name.len - 4]);
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
            try map.put(stem, full);
        }
    }
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn dirMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    cfg: *const cli.Config,
) !u8 {
    var map_a = std.StringHashMap([]const u8).init(allocator);
    var map_b = std.StringHashMap([]const u8).init(allocator);
    try collectPngs(allocator, io, cfg.a, &map_a);
    try collectPngs(allocator, io, cfg.b, &map_b);

    var stems = std.array_list.Managed([]const u8).init(allocator);
    var only_a = std.array_list.Managed([]const u8).init(allocator);
    var only_b = std.array_list.Managed([]const u8).init(allocator);

    var it = map_a.iterator();
    while (it.next()) |e| {
        if (map_b.contains(e.key_ptr.*)) {
            try stems.append(e.key_ptr.*);
        } else {
            try only_a.append(e.key_ptr.*);
        }
    }
    var it_b = map_b.iterator();
    while (it_b.next()) |e| {
        if (!map_a.contains(e.key_ptr.*)) try only_b.append(e.key_ptr.*);
    }

    std.mem.sort([]const u8, stems.items, {}, lessStr);
    std.mem.sort([]const u8, only_a.items, {}, lessStr);
    std.mem.sort([]const u8, only_b.items, {}, lessStr);

    if (cfg.diff_dir) |dd| try std.Io.Dir.cwd().createDirPath(io, dd);
    if (cfg.delta_bin) |dd| try std.Io.Dir.cwd().createDirPath(io, dd);

    const n_pairs = stems.items.len;
    const reports = try allocator.alloc(PairReport, n_pairs);
    for (reports) |*r| r.* = .{};

    var next_idx = std.atomic.Value(usize).init(0);
    const n_workers: usize = @max(1, @min(@as(usize, cfg.threads), @max(n_pairs, 1)));
    const persist_arenas = try allocator.alloc(std.heap.ArenaAllocator, n_workers);
    for (persist_arenas) |*pa| pa.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer for (persist_arenas) |*pa| pa.deinit();

    const Worker = struct {
        fn run(
            io_: std.Io,
            cfg_: *const cli.Config,
            map_a_: *std.StringHashMap([]const u8),
            map_b_: *std.StringHashMap([]const u8),
            stems_: [][]const u8,
            reports_: []PairReport,
            persist_: *std.heap.ArenaAllocator,
            next: *std.atomic.Value(usize),
        ) void {
            var task_arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer task_arena_inst.deinit();
            const persist_alloc = persist_.allocator();
            while (true) {
                const i = next.fetchAdd(1, .acq_rel);
                if (i >= stems_.len) return;
                _ = task_arena_inst.reset(.retain_capacity);
                const scratch = task_arena_inst.allocator();
                const stem = stems_[i];
                const path_a = map_a_.get(stem).?;
                const path_b = map_b_.get(stem).?;
                const diff_path = if (cfg_.diff_dir) |dd|
                    std.fmt.allocPrint(scratch, "{s}/{s}.png", .{ dd, stem }) catch null
                else
                    null;
                const delta_path = if (cfg_.delta_bin) |dd|
                    std.fmt.allocPrint(scratch, "{s}/{s}.delta", .{ dd, stem }) catch null
                else
                    null;
                var pair_cfg = cfg_.*;
                pair_cfg.threads = 1;
                var rep = comparePair(persist_alloc, scratch, io_, path_a, path_b, diff_path, delta_path, &pair_cfg);
                rep.stem = stem;
                reports_[i] = rep;
            }
        }
    };

    if (n_workers <= 1) {
        Worker.run(io, cfg, &map_a, &map_b, stems.items, reports, &persist_arenas[0], &next_idx);
    } else {
        const threads = try allocator.alloc(?std.Thread, n_workers);
        for (0..n_workers) |w| {
            threads[w] = std.Thread.spawn(.{}, Worker.run, .{
                io, cfg, &map_a, &map_b, stems.items, reports, &persist_arenas[w], &next_idx,
            }) catch null;
        }
        var spawned_any = false;
        for (threads) |t| if (t != null) {
            spawned_any = true;
            break;
        };
        if (!spawned_any) {
            Worker.run(io, cfg, &map_a, &map_b, stems.items, reports, &persist_arenas[0], &next_idx);
        } else {
            for (threads) |t| if (t) |th| th.join();
        }
    }

    if (cfg.json) {
        try out.writeAll("{\"pairs\":[");
        for (reports, 0..) |rep, i| {
            if (i > 0) try out.writeAll(",");
            if (rep.err) |e| {
                try report.writeErrorJson(out, .{ .stem = rep.stem }, @errorName(e));
            } else {
                try report.writeResultJson(
                    out,
                    .{ .stem = rep.stem },
                    rep.base_w,
                    rep.base_h,
                    rep.comp_w,
                    rep.comp_h,
                    cfg.threshold,
                    cfg.antialiasing,
                    rep.result,
                );
            }
        }
        try out.writeAll("]");
        if (only_a.items.len > 0) try writeJsonStrArray(out, "onlyInA", only_a.items);
        if (only_b.items.len > 0) try writeJsonStrArray(out, "onlyInB", only_b.items);
        try out.writeAll("}\n");
    } else {
        for (only_a.items) |s| try out.print("only-in-a {s}\n", .{s});
        for (only_b.items) |s| try out.print("only-in-b {s}\n", .{s});
        for (reports) |rep| {
            if (rep.err) |e| {
                try out.print("error {s} {s}\n", .{ rep.stem, @errorName(e) });
            } else {
                try report.writeResultText(
                    out,
                    rep.stem,
                    rep.base_w,
                    rep.base_h,
                    rep.comp_w,
                    rep.comp_h,
                    cfg.threshold,
                    cfg.antialiasing,
                    rep.result,
                );
            }
        }
    }

    return 0;
}

fn writeJsonStrArray(out: *std.Io.Writer, name: []const u8, items: []const []const u8) !void {
    try out.print(",\"{s}\":[", .{name});
    for (items, 0..) |s, i| {
        if (i > 0) try out.writeAll(",");
        try report.writeJsonStr(out, s);
    }
    try out.writeAll("]");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const err_w = &stderr_w.interface;

    const argv = init.minimal.args.toSlice(arena) catch {
        std.process.exit(2);
    };

    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--")) break;
        if (std.mem.eql(u8, a, "--version")) {
            try out.print("okdiff {s}\n", .{cli.version});
            try out.flush();
            std.process.exit(0);
        }
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try cli.printUsage(out);
            try out.flush();
            std.process.exit(0);
        }
    }

    var cfg = cli.parseArgs(arena, argv, err_w) catch |e| {
        try err_w.writeAll("Run 'okdiff --help' for usage.\n");
        try err_w.flush();
        if (e == error.OutOfMemory) return e;
        std.process.exit(2);
    };
    try err_w.flush();

    if (cfg.threads == 0) {
        cfg.threads = @intCast(std.Thread.getCpuCount() catch 1);
    }

    if (cfg.server) {
        try server.run(io, out, &cfg);
        try out.flush();
        return;
    }

    const a_dir = isDirectory(io, cfg.a);
    const b_dir = isDirectory(io, cfg.b);
    if (a_dir != b_dir) {
        try err_w.writeAll("error: both inputs must be files or both directories\n");
        try err_w.flush();
        std.process.exit(2);
    }

    var code: u8 = 0;
    if (a_dir) {
        code = try dirMode(arena, io, out, &cfg);
    } else {
        var rep = comparePair(arena, arena, io, cfg.a, cfg.b, cfg.diff_out, cfg.delta_bin, &cfg);
        rep.stem = cfg.a;
        if (rep.err) |e| {
            try err_w.print("error: {s}\n", .{@errorName(e)});
            try err_w.flush();
            std.process.exit(2);
        }
        if (cfg.json) {
            try report.writeResultJson(
                out,
                .{ .stem = rep.stem },
                rep.base_w,
                rep.base_h,
                rep.comp_w,
                rep.comp_h,
                cfg.threshold,
                cfg.antialiasing,
                rep.result,
            );
            try out.writeAll("\n");
        } else {
            try report.writeResultText(
                out,
                rep.stem,
                rep.base_w,
                rep.base_h,
                rep.comp_w,
                rep.comp_h,
                cfg.threshold,
                cfg.antialiasing,
                rep.result,
            );
        }
    }

    try out.flush();
    std.process.exit(code);
}
