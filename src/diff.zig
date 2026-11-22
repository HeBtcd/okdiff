const std = @import("std");
const Image = @import("image.zig").Image;
const color = @import("color.zig");
const aa = @import("aa.zig");

pub const Region = struct { x1: u32, y1: u32, x2: u32, y2: u32 };

pub const Options = struct {
    metric: color.Metric = .oklab,
    threshold: ?f32 = null,
    antialiasing: bool = false,
    diff_pixel: u32 = 0xFF0000FF,
    aa_pixel: ?u32 = null,
    output: ?OutputMode = .copy,
    diff_lines: bool = false,
    diff_cols: bool = false,
    ignore_regions: []const Region = &.{},
    delta_dump: bool = false,
    threads: u32 = 1,
};

pub const OutputMode = union(enum) { copy, mask, overlay: f32, delta_map: f32 };

pub const Result = struct {
    identical: u64 = 0,
    nonidentical: u64 = 0,
    ignored: u64 = 0,
    over_threshold: u64 = 0,
    aa_like: u64 = 0,
    ignored_diff: u64 = 0,
    overhang_base: u64 = 0,
    overhang_base_opaque: u64 = 0,
    overhang_comp: u64 = 0,
    overhang_comp_opaque: u64 = 0,
    deltas: ?[]f32 = null,
    output: ?Image = null,
    lines: []u32 = &.{},
    cols: []u32 = &.{},
};

const IgnoreRanges = struct {
    ranges: []u64,

    fn build(alloc: std.mem.Allocator, width: u32, height: u32, regions: []const Region) !?IgnoreRanges {
        if (regions.len == 0) return null;
        if (width == 0 or height == 0) return error.EmptyImage;
        var list = std.array_list.Managed(u64).init(alloc);
        defer list.deinit();

        for (regions) |r| {
            if (r.x1 > r.x2 or r.y1 > r.y2) return error.InvalidRegion;
            if (r.x1 >= width or r.y1 >= height) continue;
            const x2 = @min(r.x2, width - 1);
            const y2 = @min(r.y2, height - 1);
            var y = r.y1;
            while (y <= y2) : (y += 1) {
                const start: u64 = @as(u64, y) * width + r.x1;
                const end: u64 = @as(u64, y) * width + x2;
                try list.append((end << 32) | start);
            }
        }
        if (list.items.len == 0) return null;

        if (list.items.len > 1) {
            std.mem.sort(u64, list.items, {}, struct {
                fn lt(_: void, a: u64, b: u64) bool {
                    const as: u32 = @truncate(a);
                    const bs: u32 = @truncate(b);
                    if (as != bs) return as < bs;
                    return (a >> 32) < (b >> 32);
                }
            }.lt);

            var write: usize = 0;
            for (list.items[1..]) |item| {
                const cur_s: u32 = @truncate(list.items[write]);
                const cur_e: u32 = @truncate(list.items[write] >> 32);
                const next_s: u32 = @truncate(item);
                const next_e: u32 = @truncate(item >> 32);
                if ((cur_s / width) == (next_s / width) and next_s <= cur_e +| 1) {
                    list.items[write] = (@as(u64, @max(cur_e, next_e)) << 32) | cur_s;
                } else {
                    write += 1;
                    list.items[write] = item;
                }
            }
            list.items.len = write + 1;
        }
        return .{ .ranges = try alloc.dupe(u64, list.items) };
    }

    fn overlapPx(self: *const IgnoreRanges, width: u32, min_w: u32, min_h: u32) u64 {
        var n: u64 = 0;
        for (self.ranges) |r| {
            const start: u32 = @truncate(r);
            const end: u32 = @truncate(r >> 32);
            const y = start / width;
            if (y >= min_h) continue;
            const x1 = start % width;
            if (x1 >= min_w) continue;
            n += @min(end % width, min_w - 1) - x1 + 1;
        }
        return n;
    }

    fn contains(self: *const IgnoreRanges, offset: u32) bool {
        const N = std.simd.suggestVectorLength(u64) orelse 4;
        const n = self.ranges.len;
        const simd_end = (n / N) * N;
        const off_v: @Vector(N, u32) = @splat(offset);
        var i: usize = 0;
        while (i < simd_end) : (i += N) {
            const packed_v: @Vector(N, u64) = self.ranges[i..][0..N].*;
            const starts: @Vector(N, u32) = @truncate(packed_v);
            const ends: @Vector(N, u32) = @truncate(packed_v >> @splat(32));
            if (@reduce(.Or, (off_v >= starts) & (off_v <= ends))) return true;
        }
        while (i < n) : (i += 1) {
            const start: u32 = @truncate(self.ranges[i]);
            const end: u32 = @truncate(self.ranges[i] >> 32);
            if (offset >= start and offset <= end) return true;
        }
        return false;
    }
};

const BandResult = struct {
    nonidentical: u64 = 0,
    ignored_diff: u64 = 0,
    ignored_overhang: u64 = 0,
    over_threshold: u64 = 0,
    aa_like: u64 = 0,
    overhang_a: u64 = 0,
    overhang_a_opaque: u64 = 0,
    overhang_b: u64 = 0,
    overhang_b_opaque: u64 = 0,
    lines: std.array_list.Managed(u32),
    cols: ?[]u64 = null,

    fn appendLine(self: *BandResult, y: u32) void {
        const n = self.lines.items.len;
        if (n > 0 and self.lines.items[n - 1] == y) return;
        self.lines.append(y) catch {};
    }
};

const Ctx = struct {
    base: *const Image,
    comp: *const Image,
    out: ?*Image,
    delta_map: ?*Image,
    deltas: ?[]f32,
    delta_scale: f32,
    ignore: ?IgnoreRanges,
    opts: *const Options,
    thr2: ?f32,
    max_d2: f32,
    count_only: bool,
    allocator: std.mem.Allocator,
};

fn normDelta(ctx: *const Ctx, d2: f32) u32 {
    const d = @sqrt(d2 / ctx.max_d2) * ctx.delta_scale;
    return @intFromFloat(@max(0, @min(255, d * 255)));
}

fn processDeltaLane(
    ctx: *const Ctx,
    base_off: usize,
    comp_off: usize,
    d2_lane: f32,
    res: *BandResult,
) void {
    const opts = ctx.opts;
    if (ctx.ignore) |*ig| {
        if (ig.contains(@intCast(base_off))) {
            res.ignored_diff += 1;
            if (ctx.deltas) |d| d[base_off] = std.math.nan(f32);
            if (ctx.delta_map) |dm| dm.data[base_off] = 0;
            return;
        }
    }
    res.nonidentical += 1;
    if (ctx.deltas) |d| d[base_off] = @sqrt(d2_lane / ctx.max_d2);
    if (ctx.delta_map) |dm| {
        const v = normDelta(ctx, d2_lane);
        dm.data[base_off] = 0xFF000000 | (v << 16) | (v << 8) | v;
    }
    if (ctx.thr2 != null and d2_lane <= ctx.thr2.?) return;
    if (ctx.thr2 != null) res.over_threshold += 1;

    var is_aa = false;
    if (opts.antialiasing and d2_lane < ctx.max_d2) {
        const x: u32 = @intCast(base_off % ctx.base.width);
        const y: u32 = @intCast(base_off / ctx.base.width);
        if (aa.detect(ctx.base, x, y, ctx.comp) or blk: {
            const cx: u32 = @intCast(comp_off % ctx.comp.width);
            const cy: u32 = @intCast(comp_off / ctx.comp.width);
            break :blk aa.detect(ctx.comp, cx, cy, ctx.base);
        }) {
            is_aa = true;
        }
    }
    if (is_aa) {
        res.aa_like += 1;
        if (opts.aa_pixel) |ap| {
            if (ctx.out) |out| out.data[base_off] = ap;
        }
    } else if (ctx.out) |out| {
        out.data[base_off] = opts.diff_pixel;
    }
    const y: u32 = @intCast(base_off / ctx.base.width);
    const x: u32 = @intCast(base_off % ctx.base.width);
    if (opts.diff_lines) res.appendLine(y);
    if (res.cols) |cols| cols[x >> 6] |= @as(u64, 1) << @intCast(x & 63);
}

fn sameLayoutBand(ctx: *const Ctx, p0: usize, p1: usize, res: *BandResult) void {
    const opts = ctx.opts;
    const N = std.simd.suggestVectorLength(u32) orelse 8;
    const base_data = ctx.base.data;
    const comp_data = ctx.comp.data;

    var off = p0;
    if (ctx.count_only) {
        while (off + N <= p1) : (off += N) {
            const va: @Vector(N, u32) = base_data[off..][0..N].*;
            const vb: @Vector(N, u32) = comp_data[off..][0..N].*;
            const neq = va != vb;
            if (!@reduce(.Or, neq)) continue;
            const va_arr: [N]u32 = va;
            const vb_arr: [N]u32 = vb;
            const neq_arr: [N]bool = neq;
            for (0..N) |i| {
                if (neq_arr[i] and !color.blendWhiteEq(va_arr[i], vb_arr[i])) {
                    res.nonidentical += 1;
                }
            }
        }
        while (off < p1) : (off += 1) {
            if (!color.blendWhiteEq(base_data[off], comp_data[off])) res.nonidentical += 1;
        }
        return;
    }

    while (off + N <= p1) : (off += N) {
        const va: @Vector(N, u32) = base_data[off..][0..N].*;
        const vb: @Vector(N, u32) = comp_data[off..][0..N].*;
        const neq = va != vb;
        if (!@reduce(.Or, neq)) continue;

        const d2 = color.deltaE2V(N, opts.metric, va, vb);
        const d2_arr: [N]f32 = d2;
        const neq_arr: [N]bool = neq;
        const va_arr: [N]u32 = va;
        const vb_arr: [N]u32 = vb;
        for (0..N) |i| {
            if (neq_arr[i] and !color.blendWhiteEq(va_arr[i], vb_arr[i])) {
                processDeltaLane(ctx, off + i, off + i, d2_arr[i], res);
            }
        }
    }
    while (off < p1) : (off += 1) {
        const pa = base_data[off];
        const pb = comp_data[off];
        if (color.blendWhiteEq(pa, pb)) continue;
        const d2 = color.deltaE2V(1, opts.metric, @Vector(1, u32){pa}, @Vector(1, u32){pb});
        processDeltaLane(ctx, off, off, d2[0], res);
    }
}

fn countOpaqueSlice(data: [*]const u32, n: usize) u64 {
    const N = std.simd.suggestVectorLength(u32) orelse 8;
    var count: u64 = 0;
    var i: usize = 0;
    const zero: @Vector(N, u32) = @splat(0);
    while (i + N <= n) : (i += N) {
        const v: @Vector(N, u32) = data[i..][0..N].*;
        const opaque_mask = (v >> @splat(24)) != zero;
        count += @reduce(.Add, @select(u32, opaque_mask, @as(@Vector(N, u32), @splat(1)), zero));
    }
    while (i < n) : (i += 1) {
        if ((data[i] >> 24) != 0) count += 1;
    }
    return count;
}

const Overhang = struct { area: u64 = 0, opaque_px: u64 = 0 };

fn countOverhang(ctx: *const Ctx, data: [*]const u32, n: usize, off0: usize, is_base: bool, res: *BandResult) Overhang {
    if (is_base) {
        if (ctx.delta_map) |dm| @memset(dm.data[off0 .. off0 + n], 0);
        if (ctx.deltas) |d| @memset(d[off0 .. off0 + n], std.math.nan(f32));
    }
    if (is_base and ctx.ignore != null) {
        var area: u64 = 0;
        var opaque_px: u64 = 0;
        for (0..n) |i| {
            if (ctx.ignore.?.contains(@intCast(off0 + i))) {
                res.ignored_overhang += 1;
                continue;
            }
            area += 1;
            if ((data[i] >> 24) != 0) opaque_px += 1;
        }
        return .{ .area = area, .opaque_px = opaque_px };
    }
    return .{ .area = n, .opaque_px = countOpaqueSlice(data, n) };
}

fn layoutBand(ctx: *const Ctx, y0: u32, y1: u32, res: *BandResult) void {
    const opts = ctx.opts;
    const base = ctx.base;
    const comp = ctx.comp;
    const min_w = @min(base.width, comp.width);
    const min_h = @min(base.height, comp.height);
    const N = std.simd.suggestVectorLength(u32) orelse 8;

    var y = y0;
    while (y < y1) : (y += 1) {
        if (y < min_h) {
            const base_row = y * base.width;
            const comp_row = y * comp.width;
            var x: usize = 0;
            while (x + N <= min_w) : (x += N) {
                const va: @Vector(N, u32) = base.data[base_row + x ..][0..N].*;
                const vb: @Vector(N, u32) = comp.data[comp_row + x ..][0..N].*;
                const neq = va != vb;
                if (!@reduce(.Or, neq)) continue;
                const d2 = color.deltaE2V(N, opts.metric, va, vb);
                const neq_arr: [N]bool = neq;
                const d2_arr: [N]f32 = d2;
                const va_arr: [N]u32 = va;
                const vb_arr: [N]u32 = vb;
                for (0..N) |i| {
                    if (neq_arr[i] and !color.blendWhiteEq(va_arr[i], vb_arr[i])) {
                        processDeltaLane(ctx, base_row + x + i, comp_row + x + i, d2_arr[i], res);
                    }
                }
            }
            while (x < min_w) : (x += 1) {
                const pa = base.data[base_row + x];
                const pb = comp.data[comp_row + x];
                if (!color.blendWhiteEq(pa, pb)) {
                    const d2 = color.deltaE2V(1, opts.metric, @Vector(1, u32){pa}, @Vector(1, u32){pb});
                    processDeltaLane(ctx, base_row + x, comp_row + x, d2[0], res);
                }
            }
            if (base.width > comp.width) {
                const o = countOverhang(ctx, base.data + base_row + comp.width, base.width - comp.width, base_row + comp.width, true, res);
                res.overhang_a += o.area;
                res.overhang_a_opaque += o.opaque_px;
            } else if (comp.width > base.width) {
                const o = countOverhang(ctx, comp.data + comp_row + base.width, comp.width - base.width, comp_row + base.width, false, res);
                res.overhang_b += o.area;
                res.overhang_b_opaque += o.opaque_px;
            }
        } else {
            if (y < base.height) {
                const o = countOverhang(ctx, base.data + y * base.width, base.width, y * base.width, true, res);
                res.overhang_a += o.area;
                res.overhang_a_opaque += o.opaque_px;
            }
            if (y < comp.height) {
                const o = countOverhang(ctx, comp.data + y * comp.width, comp.width, y * comp.width, false, res);
                res.overhang_b += o.area;
                res.overhang_b_opaque += o.opaque_px;
            }
        }
    }
}

fn mergeResults(
    allocator: std.mem.Allocator,
    bands: []BandResult,
    result: *Result,
    max_width: u32,
    want_cols: bool,
) !void {
    var total_lines: usize = 0;
    for (bands) |b| total_lines += b.lines.items.len;
    if (total_lines > 0) {
        const lines = try allocator.alloc(u32, total_lines);
        var i: usize = 0;
        for (bands) |b| {
            @memcpy(lines[i .. i + b.lines.items.len], b.lines.items);
            i += b.lines.items.len;
        }
        result.lines = lines;
    }
    if (want_cols) {
        const n_words = (@as(usize, max_width) + 63) / 64;
        const words = try allocator.alloc(u64, n_words);
        defer allocator.free(words);
        @memset(words, 0);
        for (bands) |b| {
            if (b.cols) |c| {
                for (words, 0..) |*w, wi| w.* |= c[wi];
            }
        }
        var total: usize = 0;
        for (words) |w| total += @popCount(w);
        const cols = try allocator.alloc(u32, total);
        var i: usize = 0;
        for (words, 0..) |word, wi| {
            var v = word;
            while (v != 0) {
                const bit: u32 = @intCast(@ctz(v));
                cols[i] = @as(u32, @intCast(wi)) * 64 + bit;
                i += 1;
                v &= v - 1;
            }
        }
        result.cols = cols;
    }
}

fn BandTask(comptime layout: bool) type {
    return struct {
        ctx: *const Ctx,
        r0: usize,
        r1: usize,
        res: *BandResult,
        fn run(self: @This()) void {
            if (layout) {
                layoutBand(self.ctx, @intCast(self.r0), @intCast(self.r1), self.res);
            } else {
                sameLayoutBand(self.ctx, self.r0, self.r1, self.res);
            }
        }
    };
}

pub fn compare(
    base: *const Image,
    comp: *const Image,
    options: Options,
    allocator: std.mem.Allocator,
) !Result {
    if (base.width == 0 or base.height == 0 or comp.width == 0 or comp.height == 0) return error.EmptyImage;
    var result = Result{};
    const max_w = @max(base.width, comp.width);
    const max_h = @max(base.height, comp.height);

    var output_img: ?Image = null;
    var delta_map: ?Image = null;
    var delta_scale: f32 = 1;
    if (options.output) |mode| {
        switch (mode) {
            .delta_map => |f| {
                delta_map = try base.makeBlank(allocator);
                @memset(delta_map.?.data[0 .. @as(usize, base.width) * base.height], 0xFF000000);
                delta_scale = f;
            },
            .copy => output_img = try base.dupe(allocator),
            .mask => output_img = try base.makeBlank(allocator),
            .overlay => |f| output_img = try base.makeWithWhiteOverlay(f, allocator),
        }
    }
    errdefer {
        if (output_img) |o| o.deinit(allocator);
        if (delta_map) |dm| dm.deinit(allocator);
    }

    const ignore = try IgnoreRanges.build(allocator, base.width, base.height, options.ignore_regions);
    defer if (ignore) |ig| allocator.free(ig.ranges);

    var deltas: ?[]f32 = null;
    if (options.delta_dump) {
        deltas = try allocator.alloc(f32, @as(usize, base.width) * base.height);
        @memset(deltas.?, 0);
    }
    errdefer if (deltas) |d| allocator.free(d);

    const n_threads: usize = @max(1, @min(@as(usize, options.threads), @as(usize, max_h)));
    const ctx = Ctx{
        .base = base,
        .comp = comp,
        .out = if (output_img) |*o| o else null,
        .delta_map = if (delta_map) |*dm| dm else null,
        .deltas = deltas,
        .delta_scale = delta_scale,
        .ignore = ignore,
        .opts = &options,
        .thr2 = if (options.threshold) |t|
            t * t * color.maxDelta2(options.metric)
        else
            null,
        .max_d2 = color.maxDelta2(options.metric),
        .count_only = options.threshold == null and !options.antialiasing and
            !options.diff_lines and !options.diff_cols and !options.delta_dump and
            ignore == null and delta_map == null and output_img == null,
        .allocator = allocator,
    };

    if (ignore) |*ig| {
        const area_end: usize = @as(usize, base.width) * base.height;
        for (ig.ranges) |r| {
            const s: usize = @intCast(@as(u32, @truncate(r)));
            const e: usize = @intCast(@as(u32, @truncate(r >> 32)));
            if (s >= area_end) continue;
            const ce = @min(e, area_end - 1);
            if (ctx.delta_map) |dm| @memset(dm.data[s .. ce + 1], 0);
            if (deltas) |d| @memset(d[s .. ce + 1], std.math.nan(f32));
        }
    }

    const same_layout = base.width == comp.width and base.height == comp.height;
    const n_words = (@as(usize, max_w) + 63) / 64;

    var bands = try allocator.alloc(BandResult, n_threads);
    var bands_inited: usize = 0;
    defer {
        for (bands[0..bands_inited]) |*b| {
            b.lines.deinit();
            if (b.cols) |c| allocator.free(c);
        }
        allocator.free(bands);
    }
    for (bands) |*b| {
        b.* = .{ .lines = std.array_list.Managed(u32).init(allocator) };
        bands_inited += 1;
        if (options.diff_cols) {
            b.cols = try allocator.alloc(u64, n_words);
            @memset(b.cols.?, 0);
        }
    }

    if (same_layout) {
        const total: usize = @as(usize, base.width) * base.height;
        const per = (total + n_threads - 1) / n_threads;
        const Task = BandTask(false);
        var tasks = try allocator.alloc(Task, n_threads);
        defer allocator.free(tasks);
        var threads: []?std.Thread = try allocator.alloc(?std.Thread, n_threads);
        defer allocator.free(threads);
        for (0..n_threads) |i| {
            const p0 = @min(total, i * per);
            const p1 = @min(total, p0 + per);
            tasks[i] = .{ .ctx = &ctx, .r0 = p0, .r1 = p1, .res = &bands[i] };
            threads[i] = if (i == 0) null else std.Thread.spawn(.{}, Task.run, .{tasks[i]}) catch null;
        }
        for (0..n_threads) |i| if (threads[i] == null) tasks[i].run();
        for (threads) |t| if (t) |th| th.join();
    } else {
        const per = (@as(usize, max_h) + n_threads - 1) / n_threads;
        const Task = BandTask(true);
        var tasks = try allocator.alloc(Task, n_threads);
        defer allocator.free(tasks);
        var threads: []?std.Thread = try allocator.alloc(?std.Thread, n_threads);
        defer allocator.free(threads);
        for (0..n_threads) |i| {
            const r0 = @min(@as(usize, max_h), i * per);
            const r1 = @min(@as(usize, max_h), r0 + per);
            tasks[i] = .{ .ctx = &ctx, .r0 = r0, .r1 = r1, .res = &bands[i] };
            threads[i] = if (i == 0) null else std.Thread.spawn(.{}, Task.run, .{tasks[i]}) catch null;
        }
        for (0..n_threads) |i| if (threads[i] == null) tasks[i].run();
        for (threads) |t| if (t) |th| th.join();
    }

    var ignored_overlap: u64 = 0;
    if (ignore) |*ig| ignored_overlap = ig.overlapPx(base.width, @min(base.width, comp.width), @min(base.height, comp.height));
    for (bands) |*b| {
        result.nonidentical += b.nonidentical;
        result.ignored += b.ignored_overhang;
        result.ignored_diff += b.ignored_diff;
        result.over_threshold += b.over_threshold;
        result.aa_like += b.aa_like;
        result.overhang_base += b.overhang_a;
        result.overhang_base_opaque += b.overhang_a_opaque;
        result.overhang_comp += b.overhang_b;
        result.overhang_comp_opaque += b.overhang_b_opaque;
    }
    result.ignored += ignored_overlap;
    result.identical = @as(u64, @min(base.width, comp.width)) * @min(base.height, comp.height) -
        ignored_overlap - result.nonidentical;
    try mergeResults(allocator, bands, &result, max_w, options.diff_cols);

    result.deltas = deltas;
    result.output = if (delta_map) |dm| dm else output_img;
    return result;
}
