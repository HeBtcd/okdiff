const std = @import("std");
const diff = @import("diff.zig");
const color = @import("color.zig");
const flate = std.compress.flate;

pub const OutputMode = diff.OutputMode;
pub const version = "1.0.0";

pub const Config = struct {
    a: []const u8 = "",
    b: []const u8 = "",
    diff_out: ?[]const u8 = null,
    diff_dir: ?[]const u8 = null,
    threshold: ?f32 = null,
    metric: color.Metric = .oklab,
    antialiasing: bool = false,
    aa_color: ?u32 = null,
    diff_pixel: u32 = 0xFF0000FF,
    output_mode: ?OutputMode = .copy,
    json: bool = false,
    diff_lines: bool = false,
    diff_cols: bool = false,
    crop: ?diff.Region = null,
    ignore: std.array_list.Managed(diff.Region),
    delta_bin: ?[]const u8 = null,
    threads: u32 = 0,
    server: bool = false,
    png_level: flate.Compress.Options = flate.Compress.Options.fastest,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{ .ignore = std.array_list.Managed(diff.Region).init(allocator) };
    }

    pub fn deinit(self: *Config) void {
        self.ignore.deinit();
    }
};

pub fn printUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\okdiff — SIMD pixel-measurement tool (Oklab deltaE / YIQ)
        \\reports measurements only; verdicts belong to the caller.
        \\usage:
        \\  okdiff <base.png> <comp.png> [out.png] [options]
        \\  okdiff <dirA> <dirB> --diff-dir <outdir> [options]
        \\
        \\options:
        \\  -t, --threshold <f>     count pixels with delta > t (metric units);
        \\                        omitted → counted set = every differing pixel
        \\      --metric <name>     oklab (default) | yiq (odiff scale)
        \\      --aa                count AA-heuristic pixels separately (aaLike)
        \\      --aa-color <hex>    paint aaLike pixels (e.g. #ffff00)
        \\      --delta-map[=s]     out.png becomes a normalized-delta grayscale map
        \\                        (alpha=0 where no counterpart; s scales intensity)
        \\      --diff-mask         out.png = counted set on transparency
        \\      --diff-overlay <f>  out.png = base faded to white under counted set
        \\      --diff-color <hex>  counted-set pixel color (default #ff0000)
        \\      --no-diff-image     skip producing an output image (count only)
        \\      --output-diff-lines report counted-set line numbers
        \\      --output-diff-cols  report counted-set column numbers
        \\  -c, --crop <region>     x1:y1-x2:y2 (inclusive 0-based crop box)
        \\  -i, --ignore <regions>  x1:y1-x2:y2,x3:y3-x4:y4 (excluded domain)
        \\      --delta-bin <path>  raw f32 delta dump: u32 w,h + w*h f32 LE,
        \\                        NaN where unmeasured (file path; dir mode: dir)
        \\      --diff-dir <dir>    directory mode: write one output per pair
        \\  -j, --threads <n>       worker threads (default: cpu count)
        \\      --png-level <1-9>   zlib effort for output image (default 1)
        \\      --json              machine-readable output
        \\      --server            JSON-lines server mode on stdio
        \\  -h, --help              this help
        \\      --version           print version
        \\
        \\exit codes:
        \\  0  measurement completed   2  usage/IO error
        \\  (differing pixels are data, not failure — read the fields)
        \\
    );
}

const OptMatch = union(enum) {
    none,
    missing,
    value: []const u8,
};

fn matchOpt(args: []const [:0]const u8, i: *usize, long: []const u8, short: ?[]const u8) OptMatch {
    const arg = args[i.*];
    if (std.mem.startsWith(u8, arg, long) and arg.len > long.len and arg[long.len] == '=') {
        i.* += 1;
        return .{ .value = arg[long.len + 1 ..] };
    }
    const is_long = std.mem.eql(u8, arg, long);
    const is_short = if (short) |s| std.mem.eql(u8, arg, s) else false;
    if (!is_long and !is_short) return .none;
    if (i.* + 1 >= args.len) return .missing;
    i.* += 2;
    return .{ .value = args[i.* - 1] };
}

fn parseFiniteNonNeg(s: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, s) catch return null;
    if (!std.math.isFinite(v) or v < 0) return null;
    return v;
}

pub fn parseHexColor(s: []const u8) !u32 {
    var str = s;
    if (str.len > 0 and str[0] == '#') str = str[1..];
    if (str.len != 6) return error.InvalidHexColor;
    const r = try std.fmt.parseInt(u8, str[0..2], 16);
    const g = try std.fmt.parseInt(u8, str[2..4], 16);
    const b = try std.fmt.parseInt(u8, str[4..6], 16);
    return (@as(u32, 255) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
}

fn parseCoord(part: []const u8) !struct { u32, u32 } {
    var it = std.mem.splitSequence(u8, part, ":");
    const x_s = it.next() orelse return error.InvalidFormat;
    const y_s = it.next() orelse return error.InvalidFormat;
    if (it.next() != null) return error.InvalidFormat;
    return .{
        try std.fmt.parseInt(u32, x_s, 10),
        try std.fmt.parseInt(u32, y_s, 10),
    };
}

fn parseRegion(part: []const u8) !diff.Region {
    var halves = std.mem.splitSequence(u8, part, "-");
    const a = halves.next() orelse return error.InvalidFormat;
    const b = halves.next() orelse return error.InvalidFormat;
    if (halves.next() != null) return error.InvalidFormat;
    const x1, const y1 = try parseCoord(a);
    const x2, const y2 = try parseCoord(b);
    if (x1 > x2 or y1 > y2) return error.InvalidFormat;
    return .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
}

fn parseIgnoreRegions(input: []const u8, list: *std.array_list.Managed(diff.Region)) !void {
    if (input.len == 0) return error.InvalidFormat;
    var it = std.mem.splitSequence(u8, input, ",");
    while (it.next()) |part| {
        try list.append(try parseRegion(part));
    }
}

pub const ParseError = error{Usage} || std.mem.Allocator.Error || std.Io.Writer.Error;

fn requireOpt(m: OptMatch, name: []const u8, err_w: *std.Io.Writer) ParseError![]const u8 {
    return switch (m) {
        .value => |v| v,
        .missing => {
            try err_w.print("error: missing value for '{s}'\n", .{name});
            return error.Usage;
        },
        .none => unreachable,
    };
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8, err_w: *std.Io.Writer) ParseError!Config {
    var cfg = Config.init(allocator);
    errdefer cfg.deinit();
    var i: usize = 1;
    var positional: usize = 0;
    var after_dash_dash = false;

    while (i < args.len) {
        const arg = args[i];
        if (!after_dash_dash and std.mem.eql(u8, arg, "--")) {
            after_dash_dash = true;
            i += 1;
            continue;
        }
        if (after_dash_dash or !std.mem.startsWith(u8, arg, "-")) {
            switch (positional) {
                0 => cfg.a = arg,
                1 => cfg.b = arg,
                2 => cfg.diff_out = arg,
                else => {
                    try err_w.writeAll("error: too many positional arguments\n");
                    return error.Usage;
                },
            }
            positional += 1;
            i += 1;
            continue;
        }

        const thr_m = matchOpt(args, &i, "--threshold", "-t");
        if (thr_m != .none) {
            const raw = try requireOpt(thr_m, "--threshold", err_w);
            const v = parseFiniteNonNeg(raw) orelse {
                try err_w.print("error: bad --threshold '{s}'\n", .{raw});
                return error.Usage;
            };
            cfg.threshold = @floatCast(v);
            continue;
        }

        if (std.mem.eql(u8, arg, "--delta-map")) {
            cfg.output_mode = .{ .delta_map = 1.0 };
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--delta-map=")) {
            const raw = arg["--delta-map=".len..];
            const v = parseFiniteNonNeg(raw) orelse {
                try err_w.print("error: bad --delta-map scale '{s}'\n", .{raw});
                return error.Usage;
            };
            cfg.output_mode = .{ .delta_map = @floatCast(v) };
            i += 1;
            continue;
        }

        const met_m = matchOpt(args, &i, "--metric", null);
        if (met_m != .none) {
            const v = try requireOpt(met_m, "--metric", err_w);
            cfg.metric = color.parseMetric(v) orelse {
                try err_w.print("error: unknown metric '{s}'\n", .{v});
                return error.Usage;
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "--aa") or std.mem.eql(u8, arg, "--antialiasing")) {
            cfg.antialiasing = true;
            i += 1;
            continue;
        }

        const aa_m = matchOpt(args, &i, "--aa-color", null);
        if (aa_m != .none) {
            const v = try requireOpt(aa_m, "--aa-color", err_w);
            cfg.aa_color = parseHexColor(v) catch {
                try err_w.print("error: bad --aa-color '{s}'\n", .{v});
                return error.Usage;
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "--diff-mask")) {
            cfg.output_mode = .mask;
            i += 1;
            continue;
        }

        const ov_m = matchOpt(args, &i, "--diff-overlay", null);
        if (ov_m != .none) {
            const raw = try requireOpt(ov_m, "--diff-overlay", err_w);
            const v = parseFiniteNonNeg(raw) orelse {
                try err_w.print("error: bad --diff-overlay '{s}'\n", .{raw});
                return error.Usage;
            };
            if (v > 1.0) {
                try err_w.print("error: --diff-overlay must be in 0..1, got '{s}'\n", .{raw});
                return error.Usage;
            }
            cfg.output_mode = .{ .overlay = @floatCast(v) };
            continue;
        }

        const dc_m = matchOpt(args, &i, "--diff-color", null);
        if (dc_m != .none) {
            const v = try requireOpt(dc_m, "--diff-color", err_w);
            cfg.diff_pixel = parseHexColor(v) catch {
                try err_w.print("error: bad --diff-color '{s}'\n", .{v});
                return error.Usage;
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-diff-image")) {
            cfg.output_mode = null;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output-diff-lines")) {
            cfg.diff_lines = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output-diff-cols")) {
            cfg.diff_cols = true;
            i += 1;
            continue;
        }

        const cr_m = matchOpt(args, &i, "--crop", "-c");
        if (cr_m != .none) {
            const v = try requireOpt(cr_m, "--crop", err_w);
            if (v.len == 0) {
                try err_w.print("error: bad --crop region '{s}'\n", .{v});
                return error.Usage;
            }
            cfg.crop = parseRegion(v) catch {
                try err_w.print("error: bad --crop region '{s}'\n", .{v});
                return error.Usage;
            };
            continue;
        }

        const ig_m = matchOpt(args, &i, "--ignore", "-i");
        if (ig_m != .none) {
            const v = try requireOpt(ig_m, "--ignore", err_w);
            parseIgnoreRegions(v, &cfg.ignore) catch {
                try err_w.print("error: bad --ignore regions '{s}'\n", .{v});
                return error.Usage;
            };
            continue;
        }

        const db_m = matchOpt(args, &i, "--delta-bin", null);
        if (db_m != .none) {
            cfg.delta_bin = try requireOpt(db_m, "--delta-bin", err_w);
            continue;
        }

        const dd_m = matchOpt(args, &i, "--diff-dir", null);
        if (dd_m != .none) {
            cfg.diff_dir = try requireOpt(dd_m, "--diff-dir", err_w);
            continue;
        }

        const th_m = matchOpt(args, &i, "--threads", "-j");
        if (th_m != .none) {
            const v = try requireOpt(th_m, "--threads", err_w);
            cfg.threads = std.fmt.parseInt(u32, v, 10) catch {
                try err_w.print("error: bad --threads '{s}'\n", .{v});
                return error.Usage;
            };
            continue;
        }

        const pl_m = matchOpt(args, &i, "--png-level", null);
        if (pl_m != .none) {
            const v = try requireOpt(pl_m, "--png-level", err_w);
            const n = std.fmt.parseInt(u4, v, 10) catch {
                try err_w.print("error: bad --png-level '{s}'\n", .{v});
                return error.Usage;
            };
            cfg.png_level = switch (n) {
                1 => .level_1,
                2 => .level_2,
                3 => .level_3,
                4 => .level_4,
                5 => .level_5,
                6 => .level_6,
                7 => .level_7,
                8 => .level_8,
                9 => .level_9,
                else => {
                    try err_w.writeAll("error: --png-level must be 1-9\n");
                    return error.Usage;
                },
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "--json")) {
            cfg.json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--server")) {
            cfg.server = true;
            i += 1;
            continue;
        }

        try err_w.print("error: unknown option '{s}'\n", .{arg});
        return error.Usage;
    }

    if (!cfg.server and positional < 2) {
        try err_w.writeAll("error: two inputs required\n");
        return error.Usage;
    }
    return cfg;
}
