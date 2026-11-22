const std = @import("std");
const diff_mod = @import("diff.zig");
const color = @import("color.zig");
const io_mod = @import("io.zig");
const cli = @import("cli.zig");
const report = @import("report.zig");

const Request = struct {
    requestId: i64 = 0,
    command: ?[]const u8 = null,
    base: ?[]const u8 = null,
    comp: ?[]const u8 = null,
    diff: ?[]const u8 = null,
    threshold: ?f64 = null,
    metric: ?[]const u8 = null,
    antialiasing: ?bool = null,
    diffLines: ?bool = null,
    diffCols: ?bool = null,
    diffMask: ?bool = null,
    diffOverlay: ?f64 = null,
    diffColor: ?[]const u8 = null,
    aaColor: ?[]const u8 = null,
    deltaMap: ?f64 = null,
    deltaBin: ?[]const u8 = null,
    ignoreRegions: ?[]const diff_mod.Region = null,
};

pub fn run(io: std.Io, out: *std.Io.Writer, cfg: *const cli.Config) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const reader = &stdin_reader.interface;

    while (true) {
        const line = reader.takeDelimiter('\n') catch |e| switch (e) {
            error.ReadFailed => break,
            error.StreamTooLong => {
                try respondError(out, .{}, "request too long");
                continue;
            },
        } orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();

        const req = std.json.parseFromSliceLeaky(Request, arena, trimmed, .{
            .ignore_unknown_fields = true,
        }) catch {
            try respondError(out, .{}, "bad json");
            continue;
        };

        if (req.command) |cmd| {
            if (std.mem.eql(u8, cmd, "close") or std.mem.eql(u8, cmd, "exit")) break;
        }

        const id_meta = report.Meta{ .request_id = req.requestId };
        const base_path = req.base orelse {
            try respondError(out, id_meta, "missing base");
            continue;
        };
        const comp_path = req.comp orelse {
            try respondError(out, id_meta, "missing comp");
            continue;
        };

        const metric: color.Metric = if (req.metric) |m|
            color.parseMetric(m) orelse {
                try respondError(out, id_meta, "unknown metric");
                continue;
            }
        else
            cfg.metric;

        if (req.threshold) |t| {
            if (!std.math.isFinite(t) or t < 0) {
                try respondError(out, id_meta, "bad threshold");
                continue;
            }
        }
        if (req.deltaMap) |s| {
            if (!std.math.isFinite(s) or s < 0) {
                try respondError(out, id_meta, "bad deltaMap");
                continue;
            }
        }
        if (req.diffOverlay) |f| {
            if (!std.math.isFinite(f) or f < 0 or f > 1.0) {
                try respondError(out, id_meta, "bad diffOverlay");
                continue;
            }
        }

        const diff_pixel = if (req.diffColor) |c|
            cli.parseHexColor(c) catch {
                try respondError(out, id_meta, "bad diffColor");
                continue;
            }
        else
            cfg.diff_pixel;

        const aa_pixel = if (req.aaColor) |c|
            cli.parseHexColor(c) catch {
                try respondError(out, id_meta, "bad aaColor");
                continue;
            }
        else
            cfg.aa_color;

        var output_mode: ?diff_mod.OutputMode = cfg.output_mode orelse .copy;
        if (req.diffMask orelse false) output_mode = .mask;
        if (req.diffOverlay) |f| output_mode = .{ .overlay = @floatCast(f) };
        if (req.deltaMap) |s| output_mode = .{ .delta_map = @floatCast(s) };
        if (req.diff == null) output_mode = null;

        const opts = diff_mod.Options{
            .metric = metric,
            .threshold = if (req.threshold) |t| @floatCast(t) else cfg.threshold,
            .antialiasing = req.antialiasing orelse cfg.antialiasing,
            .diff_pixel = diff_pixel,
            .aa_pixel = aa_pixel,
            .output = output_mode,
            .diff_lines = req.diffLines orelse cfg.diff_lines,
            .diff_cols = req.diffCols orelse cfg.diff_cols,
            .ignore_regions = req.ignoreRegions orelse cfg.ignore.items,
            .delta_dump = req.deltaBin != null,
            .threads = cfg.threads,
        };

        handleRequest(io, out, arena, req, base_path, comp_path, opts, cfg) catch |e| {
            try respondError(out, id_meta, @errorName(e));
            continue;
        };
    }
    try out.flush();
}

fn handleRequest(
    io: std.Io,
    out: *std.Io.Writer,
    arena: std.mem.Allocator,
    req: Request,
    base_path: []const u8,
    comp_path: []const u8,
    opts: diff_mod.Options,
    cfg: *const cli.Config,
) !void {
    const imgs = try io_mod.loadTwoImages(arena, io, base_path, comp_path);
    var base = imgs.base;
    var comp = imgs.comp;

    const result = try diff_mod.compare(&base, &comp, opts, arena);

    if (req.diff) |diff_path| {
        if (result.output) |out_img| {
            try io_mod.savePng(arena, io, out_img, diff_path, cfg.png_level);
        }
    }
    if (req.deltaBin) |p| {
        try io_mod.saveDeltaBin(io, result.deltas.?, base.width, base.height, p);
    }

    try report.writeResultJson(
        out,
        .{ .request_id = req.requestId },
        base.width,
        base.height,
        comp.width,
        comp.height,
        opts.threshold,
        opts.antialiasing,
        result,
    );
    try out.writeAll("\n");
    try out.flush();
}

fn respondError(out: *std.Io.Writer, meta: report.Meta, msg: []const u8) !void {
    try report.writeErrorJson(out, meta, msg);
    try out.writeAll("\n");
    try out.flush();
}
