const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

const PngSpec = struct {
    width: u32,
    height: u32,
    bit_depth: u8 = 8,
    color_type: u8 = 6,
    interlace: u8 = 0,
    raw_scanlines: []const u8,
    plte: ?[]const u8 = null,
    trns: ?[]const u8 = null,
    split_idat: bool = false,
};

const DecodedPng = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    rgba: []u8,

    fn deinit(self: *const DecodedPng, alloc: Allocator) void {
        alloc.free(self.rgba);
    }

    fn pixelAt(self: *const DecodedPng, x: u32, y: u32) [4]u8 {
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * 4;
        return self.rgba[idx..][0..4].*;
    }
};

const DeltaBin = struct {
    width: u32,
    height: u32,
    values: []f32,

    fn deinit(self: *const DeltaBin, alloc: Allocator) void {
        alloc.free(self.values);
    }

    fn at(self: *const DeltaBin, x: u32, y: u32) f32 {
        return self.values[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }
};

const PairJson = struct {
    stem: ?[]const u8 = null,
    requestId: ?u64 = null,
    base: ?struct { w: u32, h: u32 } = null,
    comp: ?struct { w: u32, h: u32 } = null,
    identical: ?u64 = null,
    nonidentical: ?u64 = null,
    ignored: ?u64 = null,
    ignoredDiff: ?u64 = null,
    threshold: ?f64 = null,
    overThreshold: ?u64 = null,
    aaLike: ?u64 = null,
    overhangBase: ?u64 = null,
    overhangBaseOpaque: ?u64 = null,
    overhangComp: ?u64 = null,
    overhangCompOpaque: ?u64 = null,
    diffLines: ?[]u32 = null,
    diffCols: ?[]u32 = null,
    @"error": ?[]const u8 = null,
};

const DirJson = struct {
    pairs: []PairJson,
    onlyInA: ?[][]const u8 = null,
    onlyInB: ?[][]const u8 = null,
};

fn writeBe32(buf: *[4]u8, val: u32) void {
    std.mem.writeInt(u32, buf, val, .big);
}

fn readBe32(buf: *const [4]u8) u32 {
    return std.mem.readInt(u32, buf, .big);
}

fn appendChunk(out: *std.ArrayList(u8), alloc: Allocator, tag: *const [4]u8, payload: []const u8) !void {
    var len_bytes: [4]u8 = undefined;
    writeBe32(&len_bytes, @intCast(payload.len));
    try out.appendSlice(alloc, &len_bytes);
    try out.appendSlice(alloc, tag);
    try out.appendSlice(alloc, payload);

    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(payload);
    var crc_bytes: [4]u8 = undefined;
    writeBe32(&crc_bytes, crc.final());
    try out.appendSlice(alloc, &crc_bytes);
}

fn zlibCompress(alloc: Allocator, data: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(alloc, @max(@as(usize, 64), data.len + 64));
    errdefer aw.deinit();
    var c_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&aw.writer, &c_buf, .zlib, .default);
    try comp.writer.writeAll(data);
    try comp.finish();
    return try aw.toOwnedSlice();
}

fn encodePng(alloc: Allocator, spec: PngSpec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, &png_signature);

    var ihdr: [13]u8 = undefined;
    writeBe32(ihdr[0..4], spec.width);
    writeBe32(ihdr[4..8], spec.height);
    ihdr[8] = spec.bit_depth;
    ihdr[9] = spec.color_type;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = spec.interlace;
    try appendChunk(&out, alloc, "IHDR", &ihdr);

    if (spec.plte) |plte| {
        try appendChunk(&out, alloc, "PLTE", plte);
    }
    if (spec.trns) |trns| {
        try appendChunk(&out, alloc, "tRNS", trns);
    }

    const compressed = try zlibCompress(alloc, spec.raw_scanlines);
    defer alloc.free(compressed);

    if (spec.split_idat and compressed.len > 4) {
        const mid = compressed.len / 2;
        try appendChunk(&out, alloc, "IDAT", compressed[0..mid]);
        try appendChunk(&out, alloc, "IDAT", compressed[mid..]);
    } else {
        try appendChunk(&out, alloc, "IDAT", compressed);
    }

    try appendChunk(&out, alloc, "IEND", &.{});
    return try out.toOwnedSlice(alloc);
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const ia: i32 = a;
    const ib: i32 = b;
    const ic: i32 = c;
    const p = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn encodeFilteredRgba8(alloc: Allocator, w: u32, h: u32, pixels: []const [4]u8, row_filters: ?[]const u8) ![]u8 {
    const stride = @as(usize, w) * 4;
    const raw = try alloc.alloc(u8, @as(usize, h) * (1 + stride));
    defer alloc.free(raw);

    const prev_row = try alloc.alloc(u8, stride);
    defer alloc.free(prev_row);
    @memset(prev_row, 0);

    const curr_row = try alloc.alloc(u8, stride);
    defer alloc.free(curr_row);

    for (0..h) |y| {
        const f: u8 = if (row_filters) |rf| rf[y % rf.len] else 0;
        for (0..w) |x| {
            const px = pixels[y * @as(usize, w) + x];
            @memcpy(curr_row[x * 4 ..][0..4], &px);
        }
        const row_out = raw[y * (1 + stride) ..];
        row_out[0] = f;
        for (0..stride) |i| {
            const x_val = curr_row[i];
            const a_val: u8 = if (i >= 4) curr_row[i - 4] else 0;
            const b_val: u8 = prev_row[i];
            const c_val: u8 = if (i >= 4) prev_row[i - 4] else 0;
            row_out[1 + i] = switch (f) {
                0 => x_val,
                1 => x_val -% a_val,
                2 => x_val -% b_val,
                3 => x_val -% @as(u8, @intCast((@as(u16, a_val) + @as(u16, b_val)) >> 1)),
                4 => x_val -% paethPredictor(a_val, b_val, c_val),
                else => return error.InvalidFilter,
            };
        }
        @memcpy(prev_row, curr_row);
    }

    return try encodePng(alloc, .{
        .width = w,
        .height = h,
        .bit_depth = 8,
        .color_type = 6,
        .raw_scanlines = raw,
    });
}

fn encodeRgba8(alloc: Allocator, w: u32, h: u32, pixels: []const [4]u8) ![]u8 {
    return try encodeFilteredRgba8(alloc, w, h, pixels, null);
}

fn encodeRawScanlines(alloc: Allocator, h: u32, row_bytes: usize, pixel_data: []const u8) ![]u8 {
    const raw = try alloc.alloc(u8, @as(usize, h) * (1 + row_bytes));
    for (0..h) |y| {
        const dst = raw[y * (1 + row_bytes) ..];
        dst[0] = 0;
        @memcpy(dst[1 .. 1 + row_bytes], pixel_data[y * row_bytes ..][0..row_bytes]);
    }
    return raw;
}

fn decodePng(alloc: Allocator, bytes: []const u8) !DecodedPng {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &png_signature)) {
        return error.BadSignature;
    }

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var seen_ihdr = false;
    var seen_iend = false;

    var idat_buf: std.ArrayList(u8) = .empty;
    defer idat_buf.deinit(alloc);

    while (pos + 12 <= bytes.len) {
        const len = readBe32(bytes[pos..][0..4]);
        const tag = bytes[pos + 4 ..][0..4];
        const payload_start = pos + 8;
        const payload_end = payload_start + @as(usize, len);
        if (payload_end + 4 > bytes.len) return error.TruncatedChunk;
        const payload = bytes[payload_start..payload_end];

        var crc = std.hash.Crc32.init();
        crc.update(tag);
        crc.update(payload);
        const expected_crc = readBe32(bytes[payload_end..][0..4]);
        if (crc.final() != expected_crc) return error.BadCrc;

        if (std.mem.eql(u8, tag, "IHDR")) {
            if (payload.len != 13) return error.BadIhdr;
            width = readBe32(payload[0..4]);
            height = readBe32(payload[4..8]);
            bit_depth = payload[8];
            color_type = payload[9];
            if (payload[10] != 0 or payload[11] != 0 or payload[12] != 0) return error.UnsupportedIhdr;
            seen_ihdr = true;
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            try idat_buf.appendSlice(alloc, payload);
        } else if (std.mem.eql(u8, tag, "IEND")) {
            seen_iend = true;
            pos = payload_end + 4;
            break;
        }
        pos = payload_end + 4;
    }

    if (!seen_ihdr or !seen_iend or width == 0 or height == 0 or bit_depth != 8) {
        return error.UnsupportedDecodedPng;
    }

    const channels: usize = switch (color_type) {
        0 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => return error.UnsupportedColorType,
    };

    var r: std.Io.Reader = .fixed(idat_buf.items);
    var d_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&r, .zlib, &d_buf);
    const stride = @as(usize, width) * channels;
    const expected_raw = @as(usize, height) * (1 + stride);
    const raw = try decomp.reader.allocRemaining(alloc, .limited(expected_raw + 1024));
    defer alloc.free(raw);
    if (raw.len != expected_raw) return error.BadIdatLength;

    const prev_row = try alloc.alloc(u8, stride);
    defer alloc.free(prev_row);
    @memset(prev_row, 0);

    const curr_row = try alloc.alloc(u8, stride);
    defer alloc.free(curr_row);

    const rgba = try alloc.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    errdefer alloc.free(rgba);

    for (0..height) |y| {
        const row_in = raw[y * (1 + stride) ..];
        const f = row_in[0];
        for (0..stride) |i| {
            const x_val = row_in[1 + i];
            const a_val: u8 = if (i >= channels) curr_row[i - channels] else 0;
            const b_val: u8 = prev_row[i];
            const c_val: u8 = if (i >= channels) prev_row[i - channels] else 0;
            curr_row[i] = switch (f) {
                0 => x_val,
                1 => x_val +% a_val,
                2 => x_val +% b_val,
                3 => x_val +% @as(u8, @intCast((@as(u16, a_val) + @as(u16, b_val)) >> 1)),
                4 => x_val +% paethPredictor(a_val, b_val, c_val),
                else => return error.InvalidFilter,
            };
        }
        @memcpy(prev_row, curr_row);

        for (0..width) |x| {
            const dst = rgba[(y * @as(usize, width) + x) * 4 ..][0..4];
            switch (color_type) {
                0 => {
                    const g = curr_row[x];
                    dst.* = .{ g, g, g, 255 };
                },
                2 => {
                    dst.* = .{ curr_row[x * 3], curr_row[x * 3 + 1], curr_row[x * 3 + 2], 255 };
                },
                4 => {
                    const g = curr_row[x * 2];
                    dst.* = .{ g, g, g, curr_row[x * 2 + 1] };
                },
                6 => {
                    dst.* = curr_row[x * 4 ..][0..4].*;
                },
                else => unreachable,
            }
        }
    }

    return .{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .rgba = rgba,
    };
}

fn writeFileBytes(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
}

fn readFileBytes(alloc: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return try dir.readFileAlloc(io, sub_path, alloc, .limited(16 * 1024 * 1024));
}

fn pathExists(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}

fn joinPath(alloc: Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(alloc, parts);
}

fn runOkdiff(alloc: Allocator, io: std.Io, args: []const []const u8) !std.process.RunResult {
    const argv = try alloc.alloc([]const u8, args.len + 1);
    defer alloc.free(argv);
    argv[0] = build_options.bin_path;
    @memcpy(argv[1..], args);
    return try std.process.run(alloc, io, .{ .argv = argv });
}

fn readDeltaBin(alloc: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !DeltaBin {
    const bytes = try readFileBytes(alloc, io, dir, sub_path);
    defer alloc.free(bytes);
    if (bytes.len < 8) return error.InvalidDeltaBin;
    const w = std.mem.readInt(u32, bytes[0..4], .little);
    const h = std.mem.readInt(u32, bytes[4..8], .little);
    const count = @as(usize, w) * @as(usize, h);
    if (bytes.len != 8 + count * 4) return error.InvalidDeltaBinSize;
    const values = try alloc.alloc(f32, count);
    for (0..count) |i| {
        const bits = std.mem.readInt(u32, bytes[8 + i * 4 ..][0..4], .little);
        values[i] = @bitCast(bits);
    }
    return .{ .width = w, .height = h, .values = values };
}

fn expectExited(res: std.process.RunResult, code: u8) !void {
    try std.testing.expectEqual(std.process.Child.Term{ .exited = code }, res.term);
}

fn readServerLine(reader: *std.Io.Reader) ![]const u8 {
    const line = try reader.takeDelimiter('\n') orelse return error.UnexpectedEof;
    return std.mem.trimEnd(u8, line, "\r");
}

test "cli --help and --version exit 0" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const help_res = try runOkdiff(alloc, io, &.{"--help"});
    defer alloc.free(help_res.stdout);
    defer alloc.free(help_res.stderr);
    try expectExited(help_res, 0);
    try std.testing.expectEqualStrings("", help_res.stderr);
    try std.testing.expect(std.mem.indexOf(u8, help_res.stdout, "okdiff") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_res.stdout, "--metric") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_res.stdout, "--crop") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_res.stdout, "--delta-bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_res.stdout, "--server") != null);

    const short_help = try runOkdiff(alloc, io, &.{"-h"});
    defer alloc.free(short_help.stdout);
    defer alloc.free(short_help.stderr);
    try expectExited(short_help, 0);
    try std.testing.expectEqualStrings("", short_help.stderr);
    try std.testing.expect(short_help.stdout.len > 0);

    const ver_res = try runOkdiff(alloc, io, &.{"--version"});
    defer alloc.free(ver_res.stdout);
    defer alloc.free(ver_res.stderr);
    try expectExited(ver_res, 0);
    try std.testing.expectEqualStrings("", ver_res.stderr);
    try std.testing.expect(std.mem.startsWith(u8, ver_res.stdout, "okdiff "));
}

test "identical vs differing pairs in text and json with threshold variations" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const base_px = [_][4]u8{
        .{ 0, 0, 0, 255 },       .{ 100, 100, 100, 255 }, .{ 20, 40, 60, 255 }, .{ 255, 255, 255, 255 },
        .{ 10, 20, 30, 255 },    .{ 40, 50, 60, 255 },    .{ 70, 80, 90, 255 }, .{ 110, 120, 130, 255 },
        .{ 140, 150, 160, 255 }, .{ 170, 180, 190, 255 }, .{ 5, 15, 25, 255 },  .{ 35, 45, 55, 255 },
        .{ 65, 75, 85, 255 },    .{ 95, 105, 115, 255 },  .{ 125, 135, 145, 255 }, .{ 200, 200, 200, 255 },
    };
    var one_px = base_px;
    one_px[0] = .{ 255, 255, 255, 255 };

    var multi_px = base_px;
    multi_px[1] = .{ 103, 100, 100, 255 };
    multi_px[4] = .{ 255, 255, 255, 255 };
    multi_px[15] = .{ 255, 0, 0, 255 };

    const base_bytes = try encodeRgba8(alloc, 4, 4, &base_px);
    defer alloc.free(base_bytes);
    const same_bytes = try encodeRgba8(alloc, 4, 4, &base_px);
    defer alloc.free(same_bytes);
    const one_bytes = try encodeRgba8(alloc, 4, 4, &one_px);
    defer alloc.free(one_bytes);
    const multi_bytes = try encodeRgba8(alloc, 4, 4, &multi_px);
    defer alloc.free(multi_bytes);

    try writeFileBytes(io, tmp.dir, "base.png", base_bytes);
    try writeFileBytes(io, tmp.dir, "same.png", same_bytes);
    try writeFileBytes(io, tmp.dir, "one.png", one_bytes);
    try writeFileBytes(io, tmp.dir, "multi.png", multi_bytes);

    const p_base = try joinPath(alloc, &.{ root, "base.png" });
    defer alloc.free(p_base);
    const p_same = try joinPath(alloc, &.{ root, "same.png" });
    defer alloc.free(p_same);
    const p_one = try joinPath(alloc, &.{ root, "one.png" });
    defer alloc.free(p_one);
    const p_multi = try joinPath(alloc, &.{ root, "multi.png" });
    defer alloc.free(p_multi);

    {
        const res = try runOkdiff(alloc, io, &.{ p_base, p_same, "--no-diff-image" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        try std.testing.expectEqualStrings("", res.stderr);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "base=4x4 comp=4x4 identical=16 nonidentical=0") != null);
    }

    {
        const res = try runOkdiff(alloc, io, &.{ p_base, p_same, "--no-diff-image", "--json" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        try std.testing.expectEqualStrings("", res.stderr);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u32, 4), parsed.value.base.?.w);
        try std.testing.expectEqual(@as(u32, 4), parsed.value.base.?.h);
        try std.testing.expectEqual(@as(u64, 16), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 0), parsed.value.nonidentical.?);
        try std.testing.expect(parsed.value.threshold == null);
        try std.testing.expect(parsed.value.overThreshold == null);
        try std.testing.expect(parsed.value.@"error" == null);
    }

    {
        const res = try runOkdiff(alloc, io, &.{ p_base, p_one, "--no-diff-image", "--json" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 15), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 1), parsed.value.nonidentical.?);
        try std.testing.expect(parsed.value.threshold == null);
        try std.testing.expect(parsed.value.overThreshold == null);
    }

    {
        const res = try runOkdiff(alloc, io, &.{ p_base, p_multi, "--no-diff-image" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "base=4x4 comp=4x4 identical=13 nonidentical=3") != null);
    }

    {
        const res = try runOkdiff(alloc, io, &.{ p_base, p_multi, "--no-diff-image", "--json", "-t", "0.05" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 13), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 3), parsed.value.nonidentical.?);
        try std.testing.expectApproxEqAbs(@as(f64, 0.05), parsed.value.threshold.?, 1e-6);
        try std.testing.expectEqual(@as(u64, 2), parsed.value.overThreshold.?);
    }

    {
        const res = try runOkdiff(alloc, io, &.{ p_base, p_multi, "--no-diff-image", "--json", "-t", "0" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 3), parsed.value.overThreshold.?);
    }

    {
        const res = try runOkdiff(alloc, io, &.{ p_base, p_multi, "--no-diff-image", "--json", "-t", "2.0" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 3), parsed.value.nonidentical.?);
        try std.testing.expectEqual(@as(u64, 0), parsed.value.overThreshold.?);
    }
}

test "alpha-blending onto #ffffff before identical and nonidentical counting" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const blend_base_px = [_][4]u8{
        .{ 255, 0, 0, 0 },
        .{ 255, 255, 255, 128 },
        .{ 0, 0, 0, 0 },
    };
    const blend_comp_px = [_][4]u8{
        .{ 255, 255, 255, 255 },
        .{ 255, 255, 255, 255 },
        .{ 255, 255, 255, 255 },
    };
    const bb_bytes = try encodeRgba8(alloc, 3, 1, &blend_base_px);
    defer alloc.free(bb_bytes);
    const bc_bytes = try encodeRgba8(alloc, 3, 1, &blend_comp_px);
    defer alloc.free(bc_bytes);

    try writeFileBytes(io, tmp.dir, "blend_base.png", bb_bytes);
    try writeFileBytes(io, tmp.dir, "blend_comp.png", bc_bytes);

    const p_bb = try joinPath(alloc, &.{ root, "blend_base.png" });
    defer alloc.free(p_bb);
    const p_bc = try joinPath(alloc, &.{ root, "blend_comp.png" });
    defer alloc.free(p_bc);
    const p_bin_ok = try joinPath(alloc, &.{ root, "blend_ok.delta" });
    defer alloc.free(p_bin_ok);
    const p_bin_yiq = try joinPath(alloc, &.{ root, "blend_yiq.delta" });
    defer alloc.free(p_bin_yiq);

    for ([_][]const u8{ "oklab", "yiq" }) |metric| {
        const bin_path = if (std.mem.eql(u8, metric, "oklab")) p_bin_ok else p_bin_yiq;
        const res = try runOkdiff(alloc, io, &.{ p_bb, p_bc, "--no-diff-image", "--json", "--metric", metric, "--delta-bin", bin_path });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        try std.testing.expectEqualStrings("", res.stderr);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 3), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 0), parsed.value.nonidentical.?);
    }

    const db_ok = try readDeltaBin(alloc, io, tmp.dir, "blend_ok.delta");
    defer db_ok.deinit(alloc);
    const db_yiq = try readDeltaBin(alloc, io, tmp.dir, "blend_yiq.delta");
    defer db_yiq.deinit(alloc);
    for (0..3) |x| {
        const ux: u32 = @intCast(x);
        try std.testing.expectEqual(@as(f32, 0.0), db_ok.at(ux, 0));
        try std.testing.expectEqual(@as(f32, 0.0), db_yiq.at(ux, 0));
    }

    const mixed_base_px = [_][4]u8{
        .{ 255, 0, 0, 0 },
        .{ 255, 255, 255, 128 },
        .{ 0, 0, 0, 128 },
        .{ 255, 0, 0, 128 },
    };
    const mixed_comp_px = [_][4]u8{
        .{ 255, 255, 255, 255 },
        .{ 255, 255, 255, 255 },
        .{ 255, 255, 255, 255 },
        .{ 255, 255, 255, 255 },
    };
    const mb_bytes = try encodeRgba8(alloc, 4, 1, &mixed_base_px);
    defer alloc.free(mb_bytes);
    const mc_bytes = try encodeRgba8(alloc, 4, 1, &mixed_comp_px);
    defer alloc.free(mc_bytes);
    try writeFileBytes(io, tmp.dir, "mixed_base.png", mb_bytes);
    try writeFileBytes(io, tmp.dir, "mixed_comp.png", mc_bytes);
    const p_mb = try joinPath(alloc, &.{ root, "mixed_base.png" });
    defer alloc.free(p_mb);
    const p_mc = try joinPath(alloc, &.{ root, "mixed_comp.png" });
    defer alloc.free(p_mc);

    const mixed_res = try runOkdiff(alloc, io, &.{ p_mb, p_mc, "--no-diff-image", "--json" });
    defer alloc.free(mixed_res.stdout);
    defer alloc.free(mixed_res.stderr);
    try expectExited(mixed_res, 0);
    const mixed_parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, mixed_res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer mixed_parsed.deinit();
    try std.testing.expectEqual(@as(u64, 2), mixed_parsed.value.identical.?);
    try std.testing.expectEqual(@as(u64, 2), mixed_parsed.value.nonidentical.?);
}

test "metric oklab vs yiq divergence on perceptual brightness vs color saturation" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const a_px = [_][4]u8{
        .{ 0, 0, 0, 255 },
        .{ 205, 205, 205, 255 },
        .{ 128, 128, 128, 255 },
    };
    const b_px = [_][4]u8{
        .{ 50, 50, 50, 255 },
        .{ 255, 255, 255, 255 },
        .{ 128, 175, 80, 255 },
    };
    const a_bytes = try encodeRgba8(alloc, 3, 1, &a_px);
    defer alloc.free(a_bytes);
    const b_bytes = try encodeRgba8(alloc, 3, 1, &b_px);
    defer alloc.free(b_bytes);

    try writeFileBytes(io, tmp.dir, "a.png", a_bytes);
    try writeFileBytes(io, tmp.dir, "b.png", b_bytes);

    const p_a = try joinPath(alloc, &.{ root, "a.png" });
    defer alloc.free(p_a);
    const p_b = try joinPath(alloc, &.{ root, "b.png" });
    defer alloc.free(p_b);
    const p_ok = try joinPath(alloc, &.{ root, "ok.delta" });
    defer alloc.free(p_ok);
    const p_yiq = try joinPath(alloc, &.{ root, "yiq.delta" });
    defer alloc.free(p_yiq);

    {
        const r_ok = try runOkdiff(alloc, io, &.{ p_a, p_b, "--no-diff-image", "--metric", "oklab", "--delta-bin", p_ok });
        defer alloc.free(r_ok.stdout);
        defer alloc.free(r_ok.stderr);
        try expectExited(r_ok, 0);

        const r_yiq = try runOkdiff(alloc, io, &.{ p_a, p_b, "--no-diff-image", "--metric", "yiq", "--delta-bin", p_yiq });
        defer alloc.free(r_yiq.stdout);
        defer alloc.free(r_yiq.stderr);
        try expectExited(r_yiq, 0);
    }

    const ok_bin = try readDeltaBin(alloc, io, tmp.dir, "ok.delta");
    defer ok_bin.deinit(alloc);
    const yiq_bin = try readDeltaBin(alloc, io, tmp.dir, "yiq.delta");
    defer yiq_bin.deinit(alloc);

    const ok_shadow = ok_bin.at(0, 0);
    const ok_bright = ok_bin.at(1, 0);
    const ok_sat = ok_bin.at(2, 0);

    const yiq_shadow = yiq_bin.at(0, 0);
    const yiq_bright = yiq_bin.at(1, 0);
    const yiq_sat = yiq_bin.at(2, 0);

    try std.testing.expect(ok_shadow > 0.0 and ok_shadow <= 1.0);
    try std.testing.expect(ok_bright > 0.0 and ok_bright <= 1.0);
    try std.testing.expect(ok_sat > 0.0 and ok_sat <= 1.0);
    try std.testing.expect(yiq_shadow > 0.0 and yiq_shadow <= 1.0);
    try std.testing.expect(yiq_bright > 0.0 and yiq_bright <= 1.0);
    try std.testing.expect(yiq_sat > 0.0 and yiq_sat <= 1.0);

    try std.testing.expect(ok_shadow > ok_bright * 1.8);
    try std.testing.expectApproxEqAbs(yiq_shadow, yiq_bright, 1e-4);

    try std.testing.expect(ok_sat > ok_bright);
    try std.testing.expect(yiq_bright > yiq_sat);

    const checkOverThreshold = struct {
        fn call(a: Allocator, io_ctx: std.Io, pa: []const u8, pb: []const u8, metric: []const u8, thresh: f32, expected: u64) !void {
            const t_str = try std.fmt.allocPrint(a, "{d:.6}", .{thresh});
            defer a.free(t_str);
            const res = try runOkdiff(a, io_ctx, &.{ pa, pb, "--no-diff-image", "--json", "--metric", metric, "-t", t_str });
            defer a.free(res.stdout);
            defer a.free(res.stderr);
            try expectExited(res, 0);
            const parsed = try std.json.parseFromSlice(PairJson, a, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try std.testing.expectEqual(expected, parsed.value.overThreshold.?);
        }
    }.call;

    try checkOverThreshold(alloc, io, p_a, p_b, "yiq", yiq_sat - 0.001, 3);
    try checkOverThreshold(alloc, io, p_a, p_b, "yiq", yiq_sat + 0.001, 2);
    try checkOverThreshold(alloc, io, p_a, p_b, "yiq", yiq_bright - 0.001, 2);
    try checkOverThreshold(alloc, io, p_a, p_b, "yiq", yiq_bright + 0.001, 0);

    try checkOverThreshold(alloc, io, p_a, p_b, "oklab", ok_bright - 0.001, 3);
    try checkOverThreshold(alloc, io, p_a, p_b, "oklab", ok_bright + 0.001, 2);
    try checkOverThreshold(alloc, io, p_a, p_b, "oklab", ok_sat + 0.001, 1);

    const bw_a = try encodeRgba8(alloc, 1, 1, &.{.{ 0, 0, 0, 255 }});
    defer alloc.free(bw_a);
    const bw_b = try encodeRgba8(alloc, 1, 1, &.{.{ 255, 255, 255, 255 }});
    defer alloc.free(bw_b);
    try writeFileBytes(io, tmp.dir, "bw_a.png", bw_a);
    try writeFileBytes(io, tmp.dir, "bw_b.png", bw_b);
    const p_bwa = try joinPath(alloc, &.{ root, "bw_a.png" });
    defer alloc.free(p_bwa);
    const p_bwb = try joinPath(alloc, &.{ root, "bw_b.png" });
    defer alloc.free(p_bwb);
    const p_bwyiq = try joinPath(alloc, &.{ root, "bw_yiq.delta" });
    defer alloc.free(p_bwyiq);
    const r_bwyiq = try runOkdiff(alloc, io, &.{ p_bwa, p_bwb, "--no-diff-image", "--metric", "yiq", "--delta-bin", p_bwyiq });
    defer alloc.free(r_bwyiq.stdout);
    defer alloc.free(r_bwyiq.stderr);
    try expectExited(r_bwyiq, 0);
    const bw_yiq_bin = try readDeltaBin(alloc, io, tmp.dir, "bw_yiq.delta");
    defer bw_yiq_bin.deinit(alloc);
    try std.testing.expect(bw_yiq_bin.at(0, 0) > 0.9 and bw_yiq_bin.at(0, 0) <= 1.0);

    const bright_a = try encodeRgba8(alloc, 1, 1, &.{a_px[1]});
    defer alloc.free(bright_a);
    const bright_b = try encodeRgba8(alloc, 1, 1, &.{b_px[1]});
    defer alloc.free(bright_b);
    const sat_a = try encodeRgba8(alloc, 1, 1, &.{a_px[2]});
    defer alloc.free(sat_a);
    const sat_b = try encodeRgba8(alloc, 1, 1, &.{b_px[2]});
    defer alloc.free(sat_b);

    try writeFileBytes(io, tmp.dir, "ba.png", bright_a);
    try writeFileBytes(io, tmp.dir, "bb.png", bright_b);
    try writeFileBytes(io, tmp.dir, "sa.png", sat_a);
    try writeFileBytes(io, tmp.dir, "sb.png", sat_b);

    const p_ba = try joinPath(alloc, &.{ root, "ba.png" });
    defer alloc.free(p_ba);
    const p_bb = try joinPath(alloc, &.{ root, "bb.png" });
    defer alloc.free(p_bb);
    const p_sa = try joinPath(alloc, &.{ root, "sa.png" });
    defer alloc.free(p_sa);
    const p_sb = try joinPath(alloc, &.{ root, "sb.png" });
    defer alloc.free(p_sb);

    const r_ok_b = try runOkdiff(alloc, io, &.{ p_ba, p_bb, "--no-diff-image", "--json", "--metric", "oklab", "-t", "0.16" });
    defer alloc.free(r_ok_b.stdout);
    defer alloc.free(r_ok_b.stderr);
    const j_ok_b = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, r_ok_b.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer j_ok_b.deinit();

    const r_ok_s = try runOkdiff(alloc, io, &.{ p_sa, p_sb, "--no-diff-image", "--json", "--metric", "oklab", "-t", "0.16" });
    defer alloc.free(r_ok_s.stdout);
    defer alloc.free(r_ok_s.stderr);
    const j_ok_s = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, r_ok_s.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer j_ok_s.deinit();

    try std.testing.expectEqual(@as(u64, 0), j_ok_b.value.overThreshold.?);
    try std.testing.expectEqual(@as(u64, 1), j_ok_s.value.overThreshold.?);

    const r_yiq_b = try runOkdiff(alloc, io, &.{ p_ba, p_bb, "--no-diff-image", "--json", "--metric", "yiq", "-t", "0.16" });
    defer alloc.free(r_yiq_b.stdout);
    defer alloc.free(r_yiq_b.stderr);
    const j_yiq_b = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, r_yiq_b.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer j_yiq_b.deinit();

    const r_yiq_s = try runOkdiff(alloc, io, &.{ p_sa, p_sb, "--no-diff-image", "--json", "--metric", "yiq", "-t", "0.16" });
    defer alloc.free(r_yiq_s.stdout);
    defer alloc.free(r_yiq_s.stderr);
    const j_yiq_s = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, r_yiq_s.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer j_yiq_s.deinit();

    try std.testing.expectEqual(@as(u64, 1), j_yiq_b.value.overThreshold.?);
    try std.testing.expectEqual(@as(u64, 0), j_yiq_s.value.overThreshold.?);
}

test "aa and aa-color count aaLike without subtracting from nonidentical or overThreshold" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var px1: [36][4]u8 = undefined;
    var px2: [36][4]u8 = undefined;
    for (0..6) |y| {
        for (0..6) |x| {
            const c: [4]u8 = if (x < y) .{ 0, 0, 0, 255 } else .{ 255, 255, 255, 255 };
            px1[y * 6 + x] = c;
            px2[y * 6 + x] = if (x == 2 and y == 2) .{ 128, 128, 128, 255 } else c;
        }
    }

    const b1 = try encodeRgba8(alloc, 6, 6, &px1);
    defer alloc.free(b1);
    const b2 = try encodeRgba8(alloc, 6, 6, &px2);
    defer alloc.free(b2);

    try writeFileBytes(io, tmp.dir, "aa1.png", b1);
    try writeFileBytes(io, tmp.dir, "aa2.png", b2);

    const p1 = try joinPath(alloc, &.{ root, "aa1.png" });
    defer alloc.free(p1);
    const p2 = try joinPath(alloc, &.{ root, "aa2.png" });
    defer alloc.free(p2);
    const p_out_aa = try joinPath(alloc, &.{ root, "out_aa.png" });
    defer alloc.free(p_out_aa);
    const p_out_plain = try joinPath(alloc, &.{ root, "out_plain.png" });
    defer alloc.free(p_out_plain);

    const r_plain = try runOkdiff(alloc, io, &.{ p1, p2, p_out_plain, "--json", "-t", "0.1" });
    defer alloc.free(r_plain.stdout);
    defer alloc.free(r_plain.stderr);
    try expectExited(r_plain, 0);
    const j_plain = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, r_plain.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer j_plain.deinit();
    try std.testing.expectEqual(@as(u64, 35), j_plain.value.identical.?);
    try std.testing.expectEqual(@as(u64, 1), j_plain.value.nonidentical.?);
    try std.testing.expectEqual(@as(u64, 1), j_plain.value.overThreshold.?);
    try std.testing.expect(j_plain.value.aaLike == null);

    const r_aa = try runOkdiff(alloc, io, &.{ p1, p2, p_out_aa, "--json", "-t", "0.1", "--aa", "--aa-color", "#ffff00", "--diff-color", "#ff0000" });
    defer alloc.free(r_aa.stdout);
    defer alloc.free(r_aa.stderr);
    try expectExited(r_aa, 0);
    const j_aa = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, r_aa.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer j_aa.deinit();
    try std.testing.expectEqual(@as(u64, 35), j_aa.value.identical.?);
    try std.testing.expectEqual(@as(u64, 1), j_aa.value.nonidentical.?);
    try std.testing.expectEqual(@as(u64, 1), j_aa.value.overThreshold.?);
    try std.testing.expectEqual(@as(u64, 1), j_aa.value.aaLike.?);

    const plain_bytes = try readFileBytes(alloc, io, tmp.dir, "out_plain.png");
    defer alloc.free(plain_bytes);
    const plain_dec = try decodePng(alloc, plain_bytes);
    defer plain_dec.deinit(alloc);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, plain_dec.pixelAt(2, 2));

    const aa_bytes = try readFileBytes(alloc, io, tmp.dir, "out_aa.png");
    defer alloc.free(aa_bytes);
    const aa_dec = try decodePng(alloc, aa_bytes);
    defer aa_dec.deinit(alloc);
    try std.testing.expectEqual([4]u8{ 255, 255, 0, 255 }, aa_dec.pixelAt(2, 2));
}

test "render outputs default mask overlay diff-color delta-map and no-diff-image" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const b_px = [_][4]u8{
        .{ 0, 0, 0, 255 },       .{ 100, 100, 100, 255 },
        .{ 20, 40, 60, 255 },    .{ 255, 255, 255, 255 },
    };
    const c_px = [_][4]u8{
        .{ 0, 0, 0, 255 },       .{ 255, 255, 255, 255 },
        .{ 20, 40, 60, 255 },    .{ 255, 255, 255, 255 },
    };
    const b_bytes = try encodeRgba8(alloc, 2, 2, &b_px);
    defer alloc.free(b_bytes);
    const c_bytes = try encodeRgba8(alloc, 2, 2, &c_px);
    defer alloc.free(c_bytes);

    try writeFileBytes(io, tmp.dir, "b.png", b_bytes);
    try writeFileBytes(io, tmp.dir, "c.png", c_bytes);

    const p_b = try joinPath(alloc, &.{ root, "b.png" });
    defer alloc.free(p_b);
    const p_c = try joinPath(alloc, &.{ root, "c.png" });
    defer alloc.free(p_c);

    const Cases = struct {
        name: []const u8,
        extra: []const []const u8,
    };
    const cases = [_]Cases{
        .{ .name = "def.png", .extra = &.{} },
        .{ .name = "mask.png", .extra = &.{"--diff-mask"} },
        .{ .name = "ov.png", .extra = &.{ "--diff-overlay", "0.5" } },
        .{ .name = "col.png", .extra = &.{ "--diff-color", "#00ff00" } },
        .{ .name = "dmap1.png", .extra = &.{"--delta-map"} },
        .{ .name = "dmap2.png", .extra = &.{"--delta-map=2.0"} },
    };

    for (cases) |case| {
        const out_path = try joinPath(alloc, &.{ root, case.name });
        defer alloc.free(out_path);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(alloc);
        try args.appendSlice(alloc, &.{ p_b, p_c, out_path });
        try args.appendSlice(alloc, case.extra);
        const res = try runOkdiff(alloc, io, args.items);
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        try std.testing.expectEqualStrings("", res.stderr);
    }

    const def_bytes = try readFileBytes(alloc, io, tmp.dir, "def.png");
    defer alloc.free(def_bytes);
    const def_dec = try decodePng(alloc, def_bytes);
    defer def_dec.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), def_dec.width);
    try std.testing.expectEqual(@as(u32, 2), def_dec.height);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, def_dec.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, def_dec.pixelAt(1, 0));

    const mask_bytes = try readFileBytes(alloc, io, tmp.dir, "mask.png");
    defer alloc.free(mask_bytes);
    const mask_dec = try decodePng(alloc, mask_bytes);
    defer mask_dec.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), mask_dec.width);
    try std.testing.expectEqual(@as(u32, 2), mask_dec.height);
    try std.testing.expectEqual(@as(u8, 0), mask_dec.pixelAt(0, 0)[3]);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, mask_dec.pixelAt(1, 0));

    const ov_bytes = try readFileBytes(alloc, io, tmp.dir, "ov.png");
    defer alloc.free(ov_bytes);
    const ov_dec = try decodePng(alloc, ov_bytes);
    defer ov_dec.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), ov_dec.width);
    try std.testing.expectEqual(@as(u32, 2), ov_dec.height);
    const ov_bg = ov_dec.pixelAt(0, 0);
    try std.testing.expect(ov_bg[0] >= 126 and ov_bg[0] <= 129);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, ov_dec.pixelAt(1, 0));

    const col_bytes = try readFileBytes(alloc, io, tmp.dir, "col.png");
    defer alloc.free(col_bytes);
    const col_dec = try decodePng(alloc, col_bytes);
    defer col_dec.deinit(alloc);
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, col_dec.pixelAt(1, 0));

    const dmap1_bytes = try readFileBytes(alloc, io, tmp.dir, "dmap1.png");
    defer alloc.free(dmap1_bytes);
    const dmap1_dec = try decodePng(alloc, dmap1_bytes);
    defer dmap1_dec.deinit(alloc);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, dmap1_dec.pixelAt(0, 0));
    try std.testing.expect(dmap1_dec.pixelAt(1, 0)[0] > 0);
    try std.testing.expectEqual(@as(u8, 255), dmap1_dec.pixelAt(1, 0)[3]);

    const dmap2_bytes = try readFileBytes(alloc, io, tmp.dir, "dmap2.png");
    defer alloc.free(dmap2_bytes);
    const dmap2_dec = try decodePng(alloc, dmap2_bytes);
    defer dmap2_dec.deinit(alloc);
    try std.testing.expect(dmap2_dec.pixelAt(1, 0)[0] > dmap1_dec.pixelAt(1, 0)[0]);

    const dmap_ign_path = try joinPath(alloc, &.{ root, "dmap_ign.png" });
    defer alloc.free(dmap_ign_path);
    const dmap_ign_res = try runOkdiff(alloc, io, &.{ p_b, p_c, dmap_ign_path, "--delta-map", "-i", "0:0-0:0" });
    defer alloc.free(dmap_ign_res.stdout);
    defer alloc.free(dmap_ign_res.stderr);
    try expectExited(dmap_ign_res, 0);
    const dmap_ign_bytes = try readFileBytes(alloc, io, tmp.dir, "dmap_ign.png");
    defer alloc.free(dmap_ign_bytes);
    const dmap_ign_dec = try decodePng(alloc, dmap_ign_bytes);
    defer dmap_ign_dec.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), dmap_ign_dec.pixelAt(0, 0)[3]);
    try std.testing.expectEqual(@as(u8, 255), dmap_ign_dec.pixelAt(1, 0)[3]);

    const skip_path = try joinPath(alloc, &.{ root, "skipped.png" });
    defer alloc.free(skip_path);
    const skip_res = try runOkdiff(alloc, io, &.{ p_b, p_c, skip_path, "--no-diff-image" });
    defer alloc.free(skip_res.stdout);
    defer alloc.free(skip_res.stderr);
    try expectExited(skip_res, 0);
    try std.testing.expect(!pathExists(io, tmp.dir, "skipped.png"));
}

test "delta-bin layout with identical diff ignore and base overhang" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const base_px = [_][4]u8{
        .{ 0, 0, 0, 255 },     .{ 10, 10, 10, 255 },  .{ 50, 50, 50, 255 }, .{ 60, 60, 60, 255 },
        .{ 20, 20, 20, 255 },  .{ 30, 30, 30, 255 },  .{ 70, 70, 70, 255 }, .{ 80, 80, 80, 255 },
    };
    const comp_px = [_][4]u8{
        .{ 0, 0, 0, 255 },     .{ 200, 10, 10, 255 },
        .{ 250, 20, 20, 255 }, .{ 30, 30, 30, 255 },
        .{ 90, 90, 90, 255 },  .{ 90, 90, 90, 255 },
    };
    const b_bytes = try encodeRgba8(alloc, 4, 2, &base_px);
    defer alloc.free(b_bytes);
    const c_bytes = try encodeRgba8(alloc, 2, 3, &comp_px);
    defer alloc.free(c_bytes);

    try writeFileBytes(io, tmp.dir, "base.png", b_bytes);
    try writeFileBytes(io, tmp.dir, "comp.png", c_bytes);

    const p_b = try joinPath(alloc, &.{ root, "base.png" });
    defer alloc.free(p_b);
    const p_c = try joinPath(alloc, &.{ root, "comp.png" });
    defer alloc.free(p_c);
    const p_bin = try joinPath(alloc, &.{ root, "out.delta" });
    defer alloc.free(p_bin);

    const res = try runOkdiff(alloc, io, &.{ p_b, p_c, "--no-diff-image", "-i", "0:1-1:1", "--delta-bin", p_bin });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    try expectExited(res, 0);
    try std.testing.expectEqualStrings("", res.stderr);

    const db = try readDeltaBin(alloc, io, tmp.dir, "out.delta");
    defer db.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 4), db.width);
    try std.testing.expectEqual(@as(u32, 2), db.height);
    try std.testing.expectEqual(@as(f32, 0.0), db.at(0, 0));
    try std.testing.expect(db.at(1, 0) > 0.0 and !std.math.isNan(db.at(1, 0)));
    try std.testing.expect(std.math.isNan(db.at(0, 1)));
    try std.testing.expect(std.math.isNan(db.at(1, 1)));
    try std.testing.expect(std.math.isNan(db.at(2, 0)));
    try std.testing.expect(std.math.isNan(db.at(3, 0)));
    try std.testing.expect(std.math.isNan(db.at(2, 1)));
    try std.testing.expect(std.math.isNan(db.at(3, 1)));
}

test "dimension mismatch overhang counts opaque vs transparent" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const c0 = [4]u8{ 0, 0, 0, 255 };
    const cW = [4]u8{ 255, 255, 255, 255 };
    const cT = [4]u8{ 10, 20, 30, 0 };
    const cS = [4]u8{ 255, 0, 0, 128 };

    const base_px = [_][4]u8{
        c0, c0, cT, cW,
        c0, c0, cS, c0,
        c0, c0, cT, cT,
    };
    const comp_px = [_][4]u8{
        c0, c0,
        c0, c0,
        c0, c0,
        cT, cW,
        cS, cT,
    };
    const b_bytes = try encodeRgba8(alloc, 4, 3, &base_px);
    defer alloc.free(b_bytes);
    const c_bytes = try encodeRgba8(alloc, 2, 5, &comp_px);
    defer alloc.free(c_bytes);

    try writeFileBytes(io, tmp.dir, "base.png", b_bytes);
    try writeFileBytes(io, tmp.dir, "comp.png", c_bytes);

    const p_b = try joinPath(alloc, &.{ root, "base.png" });
    defer alloc.free(p_b);
    const p_c = try joinPath(alloc, &.{ root, "comp.png" });
    defer alloc.free(p_c);

    const res = try runOkdiff(alloc, io, &.{ p_b, p_c, "--no-diff-image", "--json" });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    try expectExited(res, 0);
    try std.testing.expectEqualStrings("", res.stderr);

    const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 4), parsed.value.base.?.w);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.base.?.h);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.comp.?.w);
    try std.testing.expectEqual(@as(u32, 5), parsed.value.comp.?.h);
    try std.testing.expectEqual(@as(u64, 6), parsed.value.identical.?);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.nonidentical.?);
    try std.testing.expectEqual(@as(u64, 6), parsed.value.overhangBase.?);
    try std.testing.expectEqual(@as(u64, 3), parsed.value.overhangBaseOpaque.?);
    try std.testing.expectEqual(@as(u64, 4), parsed.value.overhangComp.?);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.overhangCompOpaque.?);

    const small_px = [_][4]u8{ c0, c0 };
    const small_bytes = try encodeRgba8(alloc, 2, 1, &small_px);
    defer alloc.free(small_bytes);
    try writeFileBytes(io, tmp.dir, "small2x1.png", small_bytes);
    const p_s = try joinPath(alloc, &.{ root, "small2x1.png" });
    defer alloc.free(p_s);

    const r_base_only = try runOkdiff(alloc, io, &.{ p_b, p_s, "--no-diff-image", "--json" });
    defer alloc.free(r_base_only.stdout);
    defer alloc.free(r_base_only.stderr);
    try expectExited(r_base_only, 0);
    const j_base_only = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, r_base_only.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer j_base_only.deinit();
    try std.testing.expectEqual(@as(u64, 10), j_base_only.value.overhangBase.?);
    try std.testing.expect(j_base_only.value.overhangComp == null);
}

test "overlapping and out-of-bounds ignore regions plus invalid inverted ignore" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const base_px = [_][4]u8{
        .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 },
        .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 },
        .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 },
    };
    var comp_px = base_px;
    comp_px[0] = .{ 255, 0, 0, 255 };
    comp_px[4] = .{ 0, 255, 0, 255 };
    comp_px[8] = .{ 0, 0, 255, 255 };

    const b_bytes = try encodeRgba8(alloc, 3, 3, &base_px);
    defer alloc.free(b_bytes);
    const c_bytes = try encodeRgba8(alloc, 3, 3, &comp_px);
    defer alloc.free(c_bytes);

    try writeFileBytes(io, tmp.dir, "b.png", b_bytes);
    try writeFileBytes(io, tmp.dir, "c.png", c_bytes);

    const p_b = try joinPath(alloc, &.{ root, "b.png" });
    defer alloc.free(p_b);
    const p_c = try joinPath(alloc, &.{ root, "c.png" });
    defer alloc.free(p_c);

    {
        const res = try runOkdiff(alloc, io, &.{ p_b, p_c, "--no-diff-image", "--json", "-i", "0:0-1:1,1:1-9:9" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 7), parsed.value.ignored.?);
        try std.testing.expectEqual(@as(u64, 3), parsed.value.ignoredDiff.?);
        try std.testing.expectEqual(@as(u64, 2), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 0), parsed.value.nonidentical.?);
    }

    {
        const res = try runOkdiff(alloc, io, &.{ p_b, p_c, "--no-diff-image", "--json", "-i", "10:10-20:20" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 6), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 3), parsed.value.nonidentical.?);
        try std.testing.expect(parsed.value.ignored == null);
    }

    for ([_][]const u8{ "2:0-1:2", "0:2-2:1", "bad" }) |bad_region| {
        const res = try runOkdiff(alloc, io, &.{ p_b, p_c, "--no-diff-image", "--json", "-i", bad_region });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 2);
        try std.testing.expectEqualStrings("", res.stdout);
        try std.testing.expect(res.stderr.len > 0);
    }
}

test "diff-dir multiple stems diffLines diffCols onlyInA onlyInB and per-pair corrupt error" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "dirA");
    try tmp.dir.createDirPath(io, "dirB");
    try tmp.dir.createDirPath(io, "diffOut");
    try tmp.dir.createDirPath(io, "deltaOut");

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const alpha_px = [_][4]u8{
        .{ 10, 20, 30, 255 }, .{ 40, 50, 60, 255 },
        .{ 70, 80, 90, 255 }, .{ 100, 110, 120, 255 },
    };
    const alpha_bytes = try encodeRgba8(alloc, 2, 2, &alpha_px);
    defer alloc.free(alpha_bytes);

    const beta_a_px = [_][4]u8{
        .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 },
        .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 },
        .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 },
    };
    var beta_b_px = beta_a_px;
    beta_b_px[2] = .{ 255, 0, 0, 255 };
    beta_b_px[7] = .{ 0, 255, 0, 255 };

    const beta_a = try encodeRgba8(alloc, 3, 3, &beta_a_px);
    defer alloc.free(beta_a);
    const beta_b = try encodeRgba8(alloc, 3, 3, &beta_b_px);
    defer alloc.free(beta_b);

    try writeFileBytes(io, tmp.dir, "dirA/alpha.png", alpha_bytes);
    try writeFileBytes(io, tmp.dir, "dirB/alpha.png", alpha_bytes);
    try writeFileBytes(io, tmp.dir, "dirA/beta.png", beta_a);
    try writeFileBytes(io, tmp.dir, "dirB/beta.png", beta_b);
    try writeFileBytes(io, tmp.dir, "dirA/gamma.png", alpha_bytes);
    try writeFileBytes(io, tmp.dir, "dirB/gamma.png", "not-a-png");
    try writeFileBytes(io, tmp.dir, "dirA/only_a.png", alpha_bytes);
    try writeFileBytes(io, tmp.dir, "dirB/only_b.png", alpha_bytes);

    const p_a = try joinPath(alloc, &.{ root, "dirA" });
    defer alloc.free(p_a);
    const p_b = try joinPath(alloc, &.{ root, "dirB" });
    defer alloc.free(p_b);
    const p_diff = try joinPath(alloc, &.{ root, "diffOut" });
    defer alloc.free(p_diff);
    const p_delta = try joinPath(alloc, &.{ root, "deltaOut" });
    defer alloc.free(p_delta);

    const res = try runOkdiff(alloc, io, &.{ p_a, p_b, "--diff-dir", p_diff, "--delta-bin", p_delta, "--output-diff-lines", "--output-diff-cols", "--json" });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    try expectExited(res, 0);
    try std.testing.expectEqualStrings("", res.stderr);

    const parsed = try std.json.parseFromSlice(DirJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.value.pairs.len);

    var found_alpha = false;
    var found_beta = false;
    var found_gamma = false;
    for (parsed.value.pairs) |pair| {
        if (std.mem.eql(u8, pair.stem.?, "alpha")) {
            found_alpha = true;
            try std.testing.expect(pair.@"error" == null);
            try std.testing.expectEqual(@as(u64, 4), pair.identical.?);
            try std.testing.expectEqual(@as(u64, 0), pair.nonidentical.?);
        } else if (std.mem.eql(u8, pair.stem.?, "beta")) {
            found_beta = true;
            try std.testing.expect(pair.@"error" == null);
            try std.testing.expectEqual(@as(u64, 7), pair.identical.?);
            try std.testing.expectEqual(@as(u64, 2), pair.nonidentical.?);
            try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, pair.diffLines.?);
            try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, pair.diffCols.?);
        } else if (std.mem.eql(u8, pair.stem.?, "gamma")) {
            found_gamma = true;
            try std.testing.expect(pair.@"error" != null and pair.@"error".?.len > 0);
        }
    }
    try std.testing.expect(found_alpha and found_beta and found_gamma);

    try std.testing.expectEqual(@as(usize, 1), parsed.value.onlyInA.?.len);
    try std.testing.expectEqualStrings("only_a", parsed.value.onlyInA.?[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.onlyInB.?.len);
    try std.testing.expectEqualStrings("only_b", parsed.value.onlyInB.?[0]);

    const diff_beta = try readFileBytes(alloc, io, tmp.dir, "diffOut/beta.png");
    defer alloc.free(diff_beta);
    const dec_beta = try decodePng(alloc, diff_beta);
    defer dec_beta.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 3), dec_beta.width);
    try std.testing.expectEqual(@as(u32, 3), dec_beta.height);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, dec_beta.pixelAt(2, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, dec_beta.pixelAt(1, 2));

    try std.testing.expect(pathExists(io, tmp.dir, "diffOut/alpha.png"));
    try std.testing.expect(pathExists(io, tmp.dir, "deltaOut/alpha.delta"));
    try std.testing.expect(pathExists(io, tmp.dir, "deltaOut/beta.delta"));
}

test "png color types sub-byte 16-bit filters multi-idat and invalid corrupt rejection" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const expectIdentical = struct {
        fn call(a: Allocator, io_ctx: std.Io, d: std.Io.Dir, rt: []const u8, name: []const u8, candidate: []const u8, ref_png: []const u8, total: u64) !void {
            const ref_name = try std.fmt.allocPrint(a, "{s}_ref.png", .{name});
            defer a.free(ref_name);
            const cand_name = try std.fmt.allocPrint(a, "{s}_cand.png", .{name});
            defer a.free(cand_name);

            try writeFileBytes(io_ctx, d, ref_name, ref_png);
            try writeFileBytes(io_ctx, d, cand_name, candidate);

            const p_ref = try joinPath(a, &.{ rt, ref_name });
            defer a.free(p_ref);
            const p_cand = try joinPath(a, &.{ rt, cand_name });
            defer a.free(p_cand);

            const res = try runOkdiff(a, io_ctx, &.{ p_ref, p_cand, "--no-diff-image", "--json" });
            defer a.free(res.stdout);
            defer a.free(res.stderr);
            try expectExited(res, 0);
            try std.testing.expectEqualStrings("", res.stderr);
            const parsed = try std.json.parseFromSlice(PairJson, a, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try std.testing.expectEqual(total, parsed.value.identical.?);
            try std.testing.expectEqual(@as(u64, 0), parsed.value.nonidentical.?);
        }
    }.call;

    {
        const ref_px = [_][4]u8{
            .{ 0, 0, 0, 255 },       .{ 255, 255, 255, 255 },
            .{ 255, 255, 255, 255 }, .{ 0, 0, 0, 255 },
        };
        const ref_png = try encodeRgba8(alloc, 2, 2, &ref_px);
        defer alloc.free(ref_png);

        const raw_1 = try encodeRawScanlines(alloc, 2, 1, &.{ 0x40, 0x80 });
        defer alloc.free(raw_1);
        const ct0_1 = try encodePng(alloc, .{ .width = 2, .height = 2, .bit_depth = 1, .color_type = 0, .raw_scanlines = raw_1 });
        defer alloc.free(ct0_1);
        try expectIdentical(alloc, io, tmp.dir, root, "ct0_1", ct0_1, ref_png, 4);
    }

    {
        const ref_px = [_][4]u8{
            .{ 0, 0, 0, 255 },     .{ 85, 85, 85, 255 },
            .{ 170, 170, 170, 255 }, .{ 255, 255, 255, 255 },
        };
        const ref_png = try encodeRgba8(alloc, 4, 1, &ref_px);
        defer alloc.free(ref_png);

        const raw_2 = try encodeRawScanlines(alloc, 1, 1, &.{0x1b});
        defer alloc.free(raw_2);
        const ct0_2 = try encodePng(alloc, .{ .width = 4, .height = 1, .bit_depth = 2, .color_type = 0, .raw_scanlines = raw_2 });
        defer alloc.free(ct0_2);
        try expectIdentical(alloc, io, tmp.dir, root, "ct0_2", ct0_2, ref_png, 4);
    }

    {
        const ref_px = [_][4]u8{
            .{ 0, 0, 0, 255 }, .{ 255, 255, 255, 255 },
        };
        const ref_png = try encodeRgba8(alloc, 2, 1, &ref_px);
        defer alloc.free(ref_png);

        const raw_4 = try encodeRawScanlines(alloc, 1, 1, &.{0x0f});
        defer alloc.free(raw_4);
        const ct0_4 = try encodePng(alloc, .{ .width = 2, .height = 1, .bit_depth = 4, .color_type = 0, .raw_scanlines = raw_4 });
        defer alloc.free(ct0_4);
        try expectIdentical(alloc, io, tmp.dir, root, "ct0_4", ct0_4, ref_png, 2);
    }

    {
        const ref_px = [_][4]u8{
            .{ 0, 0, 0, 0 }, .{ 128, 128, 128, 255 },
        };
        const ref_png = try encodeRgba8(alloc, 2, 1, &ref_px);
        defer alloc.free(ref_png);

        const raw_8 = try encodeRawScanlines(alloc, 1, 2, &.{ 0, 128 });
        defer alloc.free(raw_8);
        const ct0_8_trns = try encodePng(alloc, .{
            .width = 2,
            .height = 1,
            .bit_depth = 8,
            .color_type = 0,
            .raw_scanlines = raw_8,
            .trns = &.{ 0, 0 },
        });
        defer alloc.free(ct0_8_trns);
        try expectIdentical(alloc, io, tmp.dir, root, "ct0_8_trns", ct0_8_trns, ref_png, 2);

        const g16_ref_px = [_][4]u8{
            .{ 30, 30, 30, 255 }, .{ 210, 210, 210, 255 },
        };
        const g16_ref = try encodeRgba8(alloc, 2, 1, &g16_ref_px);
        defer alloc.free(g16_ref);
        const raw_g16 = try encodeRawScanlines(alloc, 1, 4, &.{ 30, 0, 210, 0 });
        defer alloc.free(raw_g16);
        const ct0_16 = try encodePng(alloc, .{ .width = 2, .height = 1, .bit_depth = 16, .color_type = 0, .raw_scanlines = raw_g16 });
        defer alloc.free(ct0_16);
        try expectIdentical(alloc, io, tmp.dir, root, "ct0_16", ct0_16, g16_ref, 2);
    }

    {
        const ref_px = [_][4]u8{
            .{ 10, 20, 30, 255 }, .{ 200, 100, 50, 255 },
            .{ 15, 25, 35, 255 }, .{ 250, 10, 120, 255 },
        };
        const ref_png = try encodeRgba8(alloc, 2, 2, &ref_px);
        defer alloc.free(ref_png);

        const rgb8_raw = try encodeRawScanlines(alloc, 2, 6, &.{
            10, 20, 30, 200, 100, 50,
            15, 25, 35, 250, 10, 120,
        });
        defer alloc.free(rgb8_raw);
        const ct2_8 = try encodePng(alloc, .{ .width = 2, .height = 2, .bit_depth = 8, .color_type = 2, .raw_scanlines = rgb8_raw });
        defer alloc.free(ct2_8);
        try expectIdentical(alloc, io, tmp.dir, root, "ct2_8", ct2_8, ref_png, 4);

        const rgb16_raw = try encodeRawScanlines(alloc, 2, 12, &.{
            10, 0, 20, 0, 30, 0, 200, 0, 100, 0, 50, 0,
            15, 0, 25, 0, 35, 0, 250, 0, 10, 0, 120, 0,
        });
        defer alloc.free(rgb16_raw);
        const ct2_16 = try encodePng(alloc, .{ .width = 2, .height = 2, .bit_depth = 16, .color_type = 2, .raw_scanlines = rgb16_raw });
        defer alloc.free(ct2_16);
        try expectIdentical(alloc, io, tmp.dir, root, "ct2_16", ct2_16, ref_png, 4);

        const filtered = try encodeFilteredRgba8(alloc, 2, 2, &ref_px, &.{ 1, 2 });
        defer alloc.free(filtered);
        try expectIdentical(alloc, io, tmp.dir, root, "flt12", filtered, ref_png, 4);

        const filtered34 = try encodeFilteredRgba8(alloc, 2, 2, &ref_px, &.{ 3, 4 });
        defer alloc.free(filtered34);
        try expectIdentical(alloc, io, tmp.dir, root, "flt34", filtered34, ref_png, 4);
    }

    {
        const plte = [_]u8{
            255, 0, 0,
            0, 255, 0,
            0, 0, 255,
            12, 34, 56,
        };
        const trns = [_]u8{ 255, 0, 128 };
        const ref_px = [_][4]u8{
            .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 0 },
            .{ 0, 0, 255, 128 }, .{ 12, 34, 56, 255 },
        };
        const ref_png = try encodeRgba8(alloc, 2, 2, &ref_px);
        defer alloc.free(ref_png);

        const raw_idx8 = try encodeRawScanlines(alloc, 2, 2, &.{ 0, 1, 2, 3 });
        defer alloc.free(raw_idx8);
        const ct3_8 = try encodePng(alloc, .{ .width = 2, .height = 2, .bit_depth = 8, .color_type = 3, .raw_scanlines = raw_idx8, .plte = &plte, .trns = &trns });
        defer alloc.free(ct3_8);
        try expectIdentical(alloc, io, tmp.dir, root, "ct3_8", ct3_8, ref_png, 4);

        const raw_idx2 = try encodeRawScanlines(alloc, 2, 1, &.{ 0x10, 0xb0 });
        defer alloc.free(raw_idx2);
        const ct3_2 = try encodePng(alloc, .{ .width = 2, .height = 2, .bit_depth = 2, .color_type = 3, .raw_scanlines = raw_idx2, .plte = &plte, .trns = &trns });
        defer alloc.free(ct3_2);
        try expectIdentical(alloc, io, tmp.dir, root, "ct3_2", ct3_2, ref_png, 4);

        const raw_idx4 = try encodeRawScanlines(alloc, 2, 1, &.{ 0x01, 0x23 });
        defer alloc.free(raw_idx4);
        const ct3_4 = try encodePng(alloc, .{ .width = 2, .height = 2, .bit_depth = 4, .color_type = 3, .raw_scanlines = raw_idx4, .plte = &plte, .trns = &trns });
        defer alloc.free(ct3_4);
        try expectIdentical(alloc, io, tmp.dir, root, "ct3_4", ct3_4, ref_png, 4);

        const ref_1bit_px = [_][4]u8{
            .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 0 },
        };
        const ref_1bit = try encodeRgba8(alloc, 2, 1, &ref_1bit_px);
        defer alloc.free(ref_1bit);
        const raw_idx1 = try encodeRawScanlines(alloc, 1, 1, &.{0x40});
        defer alloc.free(raw_idx1);
        const ct3_1 = try encodePng(alloc, .{ .width = 2, .height = 1, .bit_depth = 1, .color_type = 3, .raw_scanlines = raw_idx1, .plte = &plte, .trns = &trns });
        defer alloc.free(ct3_1);
        try expectIdentical(alloc, io, tmp.dir, root, "ct3_1", ct3_1, ref_1bit, 2);
    }

    {
        const ref_px = [_][4]u8{
            .{ 40, 40, 40, 255 }, .{ 200, 200, 200, 128 },
        };
        const ref_png = try encodeRgba8(alloc, 2, 1, &ref_px);
        defer alloc.free(ref_png);

        const raw_ga8 = try encodeRawScanlines(alloc, 1, 4, &.{ 40, 255, 200, 128 });
        defer alloc.free(raw_ga8);
        const ct4_8 = try encodePng(alloc, .{ .width = 2, .height = 1, .bit_depth = 8, .color_type = 4, .raw_scanlines = raw_ga8 });
        defer alloc.free(ct4_8);
        try expectIdentical(alloc, io, tmp.dir, root, "ct4_8", ct4_8, ref_png, 2);

        const raw_ga16 = try encodeRawScanlines(alloc, 1, 8, &.{ 40, 0, 255, 0, 200, 0, 128, 0 });
        defer alloc.free(raw_ga16);
        const ct4_16 = try encodePng(alloc, .{ .width = 2, .height = 1, .bit_depth = 16, .color_type = 4, .raw_scanlines = raw_ga16 });
        defer alloc.free(ct4_16);
        try expectIdentical(alloc, io, tmp.dir, root, "ct4_16", ct4_16, ref_png, 2);
    }

    {
        const ref_px = [_][4]u8{
            .{ 12, 34, 56, 255 }, .{ 90, 120, 150, 128 },
        };
        const ref_png = try encodeRgba8(alloc, 2, 1, &ref_px);
        defer alloc.free(ref_png);

        const raw_rgba16 = try encodeRawScanlines(alloc, 1, 16, &.{
            12, 0, 34, 0, 56, 0, 255, 0,
            90, 0, 120, 0, 150, 0, 128, 0,
        });
        defer alloc.free(raw_rgba16);
        const ct6_16 = try encodePng(alloc, .{ .width = 2, .height = 1, .bit_depth = 16, .color_type = 6, .raw_scanlines = raw_rgba16, .split_idat = true });
        defer alloc.free(ct6_16);
        try expectIdentical(alloc, io, tmp.dir, root, "ct6_16", ct6_16, ref_png, 2);
    }

    const valid_small = try encodeRgba8(alloc, 1, 1, &.{.{ 0, 0, 0, 255 }});
    defer alloc.free(valid_small);
    try writeFileBytes(io, tmp.dir, "valid1x1.png", valid_small);
    const p_valid = try joinPath(alloc, &.{ root, "valid1x1.png" });
    defer alloc.free(p_valid);

    const zero_dim = try encodePng(alloc, .{ .width = 0, .height = 0, .raw_scanlines = &.{} });
    defer alloc.free(zero_dim);
    const interlaced = try encodePng(alloc, .{ .width = 1, .height = 1, .interlace = 1, .raw_scanlines = &.{ 0, 0, 0, 0, 255 } });
    defer alloc.free(interlaced);
    const bad_ct = try encodePng(alloc, .{ .width = 1, .height = 1, .color_type = 5, .raw_scanlines = &.{ 0, 0 } });
    defer alloc.free(bad_ct);

    var no_idat: std.ArrayList(u8) = .empty;
    defer no_idat.deinit(alloc);
    try no_idat.appendSlice(alloc, &png_signature);
    var ihdr_only: [13]u8 = undefined;
    writeBe32(ihdr_only[0..4], 1);
    writeBe32(ihdr_only[4..8], 1);
    ihdr_only[8] = 8;
    ihdr_only[9] = 6;
    ihdr_only[10] = 0;
    ihdr_only[11] = 0;
    ihdr_only[12] = 0;
    try appendChunk(&no_idat, alloc, "IHDR", &ihdr_only);
    try appendChunk(&no_idat, alloc, "IEND", &.{});

    var corrupt_zlib: std.ArrayList(u8) = .empty;
    defer corrupt_zlib.deinit(alloc);
    try corrupt_zlib.appendSlice(alloc, &png_signature);
    try appendChunk(&corrupt_zlib, alloc, "IHDR", &ihdr_only);
    try appendChunk(&corrupt_zlib, alloc, "IDAT", &.{ 0x78, 0x9c, 0xff, 0xff, 0x00, 0x01 });
    try appendChunk(&corrupt_zlib, alloc, "IEND", &.{});

    const bad_cases = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "zero_dim.png", .bytes = zero_dim },
        .{ .name = "bad_sig.png", .bytes = "NOTAPNG1234567890" },
        .{ .name = "trunc_hdr.png", .bytes = valid_small[0..4] },
        .{ .name = "trunc_idat.png", .bytes = valid_small[0 .. valid_small.len - 16] },
        .{ .name = "corrupt_zlib.png", .bytes = corrupt_zlib.items },
        .{ .name = "no_idat.png", .bytes = no_idat.items },
        .{ .name = "interlaced.png", .bytes = interlaced },
        .{ .name = "bad_ct.png", .bytes = bad_ct },
    };

    for (bad_cases) |bc| {
        try writeFileBytes(io, tmp.dir, bc.name, bc.bytes);
        const p_bad = try joinPath(alloc, &.{ root, bc.name });
        defer alloc.free(p_bad);

        const res = try runOkdiff(alloc, io, &.{ p_valid, p_bad, "--no-diff-image", "--json" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 2);
        try std.testing.expectEqualStrings("", res.stdout);
        try std.testing.expect(res.stderr.len > 0);
    }
}

test "cli invalid flags and option values exit 2 with empty stdout and stderr diagnostic" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const small = try encodeRgba8(alloc, 1, 1, &.{.{ 0, 0, 0, 255 }});
    defer alloc.free(small);
    try writeFileBytes(io, tmp.dir, "a.png", small);
    try writeFileBytes(io, tmp.dir, "b.png", small);
    const p_a = try joinPath(alloc, &.{ root, "a.png" });
    defer alloc.free(p_a);
    const p_b = try joinPath(alloc, &.{ root, "b.png" });
    defer alloc.free(p_b);

    const bad_flag_combos = [_][]const []const u8{
        &.{ p_a, p_b, "--json", "-t", "bad" },
        &.{ p_a, p_b, "--json", "-t", "-0.1" },
        &.{ p_a, p_b, "--json", "-t", "nan" },
        &.{ p_a, p_b, "--json", "-t", "inf" },
        &.{ p_a, p_b, "--json", "--diff-overlay", "1.5" },
        &.{ p_a, p_b, "--json", "--diff-overlay", "-0.1" },
        &.{ p_a, p_b, "--json", "--metric", "unknown" },
        &.{ p_a, p_b, "--json", "--diff-color", "bad" },
        &.{ p_a, p_b, "--json", "--aa-color", "xyz" },
        &.{ p_a, p_b, "--json", "--delta-map=-1" },
        &.{ p_a, p_b, "--json", "--png-level", "0" },
        &.{ p_a, p_b, "--json", "--png-level", "10" },
        &.{ p_a, p_b, "--json", "--threads", "bad" },
        &.{ p_a, p_b, "--json", "--unknown-flag" },
        &.{ p_a, p_b, "--json", "-t" },
        &.{ p_a, p_b, "--json", "--metric" },
        &.{ p_a, p_b, "--json", "--ignore" },
        &.{ p_a, p_b, "--json", "--crop" },
        &.{ p_a, p_b, "--json", "-c" },
        &.{ p_a, p_b, "--json", "--crop", "bad" },
        &.{ p_a, p_b, "--json", "--crop", "2:0-1:1" },
        &.{ p_a, p_b, "--json", "--crop", "0:2-1:1" },
        &.{ p_a, p_b, "--json", "--crop", "0:0-0:0,1:1-1:1" },
        &.{ p_a, p_b, "--json", "--crop", "-1:0-0:0" },
        &.{ p_a, p_b, "--json", "--diff-overlay" },
        &.{ p_a, p_b, "--json", "--diff-color" },
        &.{ p_a, p_b, "--json", "--aa-color" },
        &.{ p_a, p_b, "--json", "--delta-bin" },
        &.{ p_a, p_b, "--json", "--diff-dir" },
        &.{ p_a, p_b, "--json", "--threads" },
        &.{ p_a, p_b, "--json", "--png-level" },
        &.{"--json"},
        &.{ p_a, "--json" },
    };

    for (bad_flag_combos) |combo| {
        const res = try runOkdiff(alloc, io, combo);
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 2);
        try std.testing.expectEqualStrings("", res.stdout);
        try std.testing.expect(res.stderr.len > 0);
    }
}

test "windows backslash and quoted filename escaping in json" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sub/dirA");
    try tmp.dir.createDirPath(io, "sub/dirB");

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    const small = try encodeRgba8(alloc, 1, 1, &.{.{ 10, 20, 30, 255 }});
    defer alloc.free(small);

    try writeFileBytes(io, tmp.dir, "sub/dirA/win's file.png", small);
    try writeFileBytes(io, tmp.dir, "sub/dirB/other's file.png", small);

    const rel_or_bs = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(alloc, "{s}\\sub\\dirA\\win's file.png", .{root})
    else
        try std.fmt.allocPrint(alloc, "{s}/sub/dirA/win's file.png", .{root});
    defer alloc.free(rel_or_bs);

    const res = try runOkdiff(alloc, io, &.{ rel_or_bs, rel_or_bs, "--no-diff-image", "--json" });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    try expectExited(res, 0);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "\\\\") != null);
    }

    const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(rel_or_bs, parsed.value.stem.?);

    const p_da = try joinPath(alloc, &.{ root, "sub", "dirA" });
    defer alloc.free(p_da);
    const p_db = try joinPath(alloc, &.{ root, "sub", "dirB" });
    defer alloc.free(p_db);
    const p_out = try joinPath(alloc, &.{ root, "sub", "out" });
    defer alloc.free(p_out);

    if (builtin.os.tag != .windows) {
        try writeFileBytes(io, tmp.dir, "sub/dirA/q\"uote\\bs.png", small);
        const p_q = try joinPath(alloc, &.{ root, "sub", "dirA", "q\"uote\\bs.png" });
        defer alloc.free(p_q);
        const q_res = try runOkdiff(alloc, io, &.{ p_q, p_q, "--no-diff-image", "--json" });
        defer alloc.free(q_res.stdout);
        defer alloc.free(q_res.stderr);
        try expectExited(q_res, 0);
        try std.testing.expect(std.mem.indexOf(u8, q_res.stdout, "\\\"") != null);
        const q_parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, q_res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer q_parsed.deinit();
        try std.testing.expectEqualStrings(p_q, q_parsed.value.stem.?);
    }

    const dir_res = try runOkdiff(alloc, io, &.{ p_da, p_db, "--diff-dir", p_out, "--json" });
    defer alloc.free(dir_res.stdout);
    defer alloc.free(dir_res.stderr);
    try expectExited(dir_res, 0);
    const dir_parsed = try std.json.parseFromSlice(DirJson, alloc, std.mem.trimEnd(u8, dir_res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
    defer dir_parsed.deinit();
    try std.testing.expectEqualStrings("other's file", dir_parsed.value.onlyInB.?[0]);
}

test "server stdio ndjson e2e correlation options error recovery and graceful close" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var px1: [36][4]u8 = undefined;
    var px2: [36][4]u8 = undefined;
    for (0..6) |y| {
        for (0..6) |x| {
            const c: [4]u8 = if (x < y) .{ 0, 0, 0, 255 } else .{ 255, 255, 255, 255 };
            px1[y * 6 + x] = c;
            px2[y * 6 + x] = if (x == 2 and y == 2) .{ 128, 128, 128, 255 } else c;
        }
    }

    const b1 = try encodeRgba8(alloc, 6, 6, &px1);
    defer alloc.free(b1);
    const b2 = try encodeRgba8(alloc, 6, 6, &px2);
    defer alloc.free(b2);
    try writeFileBytes(io, tmp.dir, "s1.png", b1);
    try writeFileBytes(io, tmp.dir, "s2.png", b2);

    const p1 = try joinPath(alloc, &.{ root, "s1.png" });
    defer alloc.free(p1);
    const p2 = try joinPath(alloc, &.{ root, "s2.png" });
    defer alloc.free(p2);
    const p_d1 = try joinPath(alloc, &.{ root, "srv_out1.png" });
    defer alloc.free(p_d1);
    const p_d2 = try joinPath(alloc, &.{ root, "srv_out2.png" });
    defer alloc.free(p_d2);
    const p_bin = try joinPath(alloc, &.{ root, "srv.delta" });
    defer alloc.free(p_bin);
    const p_missing = try joinPath(alloc, &.{ root, "missing\"quote.png" });
    defer alloc.free(p_missing);

    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.bin_path, "--server" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    var out_buf: [16384]u8 = undefined;
    var out_reader = child.stdout.?.reader(io, &out_buf);

    {
        const Req = struct {
            requestId: u64 = 101,
            base: []const u8,
            comp: []const u8,
            diff: []const u8,
            metric: []const u8 = "oklab",
            threshold: f64 = 0.1,
            antialiasing: bool = true,
            diffLines: bool = true,
            diffCols: bool = true,
            diffOverlay: f64 = 0.5,
            diffColor: []const u8 = "#00ff00",
            aaColor: []const u8 = "#ffff00",
            ignoreRegions: []const struct { x1: u32, y1: u32, x2: u32, y2: u32 },
        };
        const req_json = try std.json.Stringify.valueAlloc(alloc, Req{
            .base = p1,
            .comp = p2,
            .diff = p_d1,
            .ignoreRegions = &.{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1 }},
        }, .{});
        defer alloc.free(req_json);

        const line = try std.fmt.allocPrint(alloc, "{s}\n", .{req_json});
        defer alloc.free(line);
        try child.stdin.?.writeStreamingAll(io, line);

        const resp_line = try readServerLine(&out_reader.interface);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, resp_line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 101), parsed.value.requestId.?);
        try std.testing.expectEqual(@as(u64, 4), parsed.value.ignored.?);
        try std.testing.expectEqual(@as(u64, 0), parsed.value.ignoredDiff.?);
        try std.testing.expectEqual(@as(u64, 1), parsed.value.nonidentical.?);
        try std.testing.expectEqual(@as(u64, 1), parsed.value.overThreshold.?);
        try std.testing.expectEqual(@as(u64, 1), parsed.value.aaLike.?);
        try std.testing.expectEqualSlices(u32, &.{2}, parsed.value.diffLines.?);
        try std.testing.expectEqualSlices(u32, &.{2}, parsed.value.diffCols.?);
    }

    {
        const Req = struct {
            requestId: u64 = 102,
            base: []const u8,
            comp: []const u8,
            metric: []const u8 = "unknown",
        };
        const req_json = try std.json.Stringify.valueAlloc(alloc, Req{ .base = p1, .comp = p2 }, .{});
        defer alloc.free(req_json);
        const line = try std.fmt.allocPrint(alloc, "{s}\n", .{req_json});
        defer alloc.free(line);
        try child.stdin.?.writeStreamingAll(io, line);

        const resp_line = try readServerLine(&out_reader.interface);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, resp_line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 102), parsed.value.requestId.?);
        try std.testing.expect(parsed.value.@"error" != null and parsed.value.@"error".?.len > 0);
    }

    {
        const Req = struct {
            requestId: u64 = 103,
            base: []const u8,
            comp: []const u8,
        };
        const req_json = try std.json.Stringify.valueAlloc(alloc, Req{ .base = p_missing, .comp = p2 }, .{});
        defer alloc.free(req_json);
        const line = try std.fmt.allocPrint(alloc, "{s}\n", .{req_json});
        defer alloc.free(line);
        try child.stdin.?.writeStreamingAll(io, line);

        const resp_line = try readServerLine(&out_reader.interface);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, resp_line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 103), parsed.value.requestId.?);
        try std.testing.expect(parsed.value.@"error" != null and parsed.value.@"error".?.len > 0);
    }

    {
        try child.stdin.?.writeStreamingAll(io, "{broken json line\n");
        const resp_line = try readServerLine(&out_reader.interface);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, resp_line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expect(parsed.value.@"error" != null and parsed.value.@"error".?.len > 0);
    }

    {
        const Req = struct {
            requestId: u64 = 104,
            base: []const u8,
            comp: []const u8,
            diff: []const u8,
            metric: []const u8 = "yiq",
            diffMask: bool = true,
            deltaBin: []const u8,
        };
        const req_json = try std.json.Stringify.valueAlloc(alloc, Req{
            .base = p1,
            .comp = p2,
            .diff = p_d2,
            .deltaBin = p_bin,
        }, .{});
        defer alloc.free(req_json);
        const line = try std.fmt.allocPrint(alloc, "{s}\n", .{req_json});
        defer alloc.free(line);
        try child.stdin.?.writeStreamingAll(io, line);

        const resp_line = try readServerLine(&out_reader.interface);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, resp_line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 104), parsed.value.requestId.?);
        try std.testing.expect(parsed.value.@"error" == null);
        try std.testing.expectEqual(@as(u64, 35), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 1), parsed.value.nonidentical.?);
    }

    try child.stdin.?.writeStreamingAll(io, "{\"command\":\"close\"}\n");
    child.stdin.?.close(io);
    child.stdin = null;

    const srv_tail = try out_reader.interface.allocRemaining(alloc, .limited(4096));
    defer alloc.free(srv_tail);
    try std.testing.expectEqualStrings("", srv_tail);

    var err_buf: [4096]u8 = undefined;
    var err_reader = child.stderr.?.reader(io, &err_buf);
    const srv_err = try err_reader.interface.allocRemaining(alloc, .limited(4096));
    defer alloc.free(srv_err);

    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try std.testing.expectEqualStrings("", srv_err);

    const out1_bytes = try readFileBytes(alloc, io, tmp.dir, "srv_out1.png");
    defer alloc.free(out1_bytes);
    const out1_dec = try decodePng(alloc, out1_bytes);
    defer out1_dec.deinit(alloc);
    try std.testing.expectEqual([4]u8{ 255, 255, 0, 255 }, out1_dec.pixelAt(2, 2));

    const out2_bytes = try readFileBytes(alloc, io, tmp.dir, "srv_out2.png");
    defer alloc.free(out2_bytes);
    const out2_dec = try decodePng(alloc, out2_bytes);
    defer out2_dec.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), out2_dec.pixelAt(0, 0)[3]);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, out2_dec.pixelAt(2, 2));

    const srv_bin = try readDeltaBin(alloc, io, tmp.dir, "srv.delta");
    defer srv_bin.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 6), srv_bin.width);
    try std.testing.expectEqual(@as(u32, 6), srv_bin.height);
    try std.testing.expect(srv_bin.at(2, 2) > 0.0);

    var child2 = try std.process.spawn(io, .{
        .argv = &.{ build_options.bin_path, "--server" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child2.kill(io);
    try child2.stdin.?.writeStreamingAll(io, "{\"command\":\"exit\"}\n");
    child2.stdin.?.close(io);
    child2.stdin = null;
    var out2_buf: [1024]u8 = undefined;
    var out2_reader = child2.stdout.?.reader(io, &out2_buf);
    const out2_tail = try out2_reader.interface.allocRemaining(alloc, .limited(1024));
    defer alloc.free(out2_tail);
    try std.testing.expectEqualStrings("", out2_tail);
    var err2_buf: [1024]u8 = undefined;
    var err2_reader = child2.stderr.?.reader(io, &err2_buf);
    const err2_tail = try err2_reader.interface.allocRemaining(alloc, .limited(1024));
    defer alloc.free(err2_tail);
    try std.testing.expectEqualStrings("", err2_tail);
    const term2 = try child2.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term2);
}

test "cli and server --crop inclusive bounds, outputs, delta-bin, ignore, and out-of-bounds errors" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var base_px: [36][4]u8 = undefined;
    @memset(&base_px, .{ 255, 255, 255, 255 });
    var comp_px = base_px;
    comp_px[0 * 6 + 0] = .{ 0, 0, 0, 255 };
    comp_px[5 * 6 + 5] = .{ 0, 0, 0, 255 };
    comp_px[3 * 6 + 2] = .{ 255, 0, 0, 255 };

    const base_bytes = try encodeRgba8(alloc, 6, 6, &base_px);
    defer alloc.free(base_bytes);
    const comp_bytes = try encodeRgba8(alloc, 6, 6, &comp_px);
    defer alloc.free(comp_bytes);
    const small_bytes = try encodeRgba8(alloc, 4, 5, base_px[0..20]);
    defer alloc.free(small_bytes);

    try writeFileBytes(io, tmp.dir, "c_base.png", base_bytes);
    try writeFileBytes(io, tmp.dir, "c_comp.png", comp_bytes);
    try writeFileBytes(io, tmp.dir, "c_small.png", small_bytes);

    const p_base = try joinPath(alloc, &.{ root, "c_base.png" });
    defer alloc.free(p_base);
    const p_comp = try joinPath(alloc, &.{ root, "c_comp.png" });
    defer alloc.free(p_comp);
    const p_small = try joinPath(alloc, &.{ root, "c_small.png" });
    defer alloc.free(p_small);
    const p_mask = try joinPath(alloc, &.{ root, "crop_mask.png" });
    defer alloc.free(p_mask);
    const p_bin = try joinPath(alloc, &.{ root, "crop.delta" });
    defer alloc.free(p_bin);

    {
        const res = try runOkdiff(alloc, io, &.{
            p_base,
            p_comp,
            p_mask,
            "-c",
            "1:2-4:4",
            "--diff-mask",
            "--output-diff-lines",
            "--output-diff-cols",
            "--delta-bin",
            p_bin,
            "--json",
        });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u32, 4), parsed.value.base.?.w);
        try std.testing.expectEqual(@as(u32, 3), parsed.value.base.?.h);
        try std.testing.expectEqual(@as(u32, 4), parsed.value.comp.?.w);
        try std.testing.expectEqual(@as(u32, 3), parsed.value.comp.?.h);
        try std.testing.expectEqual(@as(u64, 11), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 1), parsed.value.nonidentical.?);
        try std.testing.expectEqualSlices(u32, &.{1}, parsed.value.diffLines.?);
        try std.testing.expectEqualSlices(u32, &.{1}, parsed.value.diffCols.?);

        const mask_bytes = try readFileBytes(alloc, io, tmp.dir, "crop_mask.png");
        defer alloc.free(mask_bytes);
        const mask_dec = try decodePng(alloc, mask_bytes);
        defer mask_dec.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 4), mask_dec.width);
        try std.testing.expectEqual(@as(u32, 3), mask_dec.height);
        try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, mask_dec.pixelAt(1, 1));
        try std.testing.expectEqual(@as(u8, 0), mask_dec.pixelAt(0, 0)[3]);

        const dbin = try readDeltaBin(alloc, io, tmp.dir, "crop.delta");
        defer dbin.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 4), dbin.width);
        try std.testing.expectEqual(@as(u32, 3), dbin.height);
        try std.testing.expectEqual(@as(f32, 0.0), dbin.at(0, 0));
        try std.testing.expect(dbin.at(1, 1) > 0.4);
    }

    {
        const res = try runOkdiff(alloc, io, &.{
            p_base,
            p_comp,
            "--no-diff-image",
            "--crop=1:2-4:4",
            "-i",
            "1:1-1:1",
            "--json",
        });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 1), parsed.value.ignored.?);
        try std.testing.expectEqual(@as(u64, 1), parsed.value.ignoredDiff.?);
        try std.testing.expectEqual(@as(u64, 11), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 0), parsed.value.nonidentical.?);
    }

    {
        const res = try runOkdiff(alloc, io, &.{ p_base, p_comp, "--no-diff-image", "-c", "0:0-0:0", "--json" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u32, 1), parsed.value.base.?.w);
        try std.testing.expectEqual(@as(u32, 1), parsed.value.base.?.h);
        try std.testing.expectEqual(@as(u64, 1), parsed.value.nonidentical.?);
    }

    {
        const res = try runOkdiff(alloc, io, &.{ p_base, p_small, "--no-diff-image", "-c", "1:1-3:4", "--json" });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 0);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, std.mem.trimEnd(u8, res.stdout, "\r\n"), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u32, 3), parsed.value.base.?.w);
        try std.testing.expectEqual(@as(u32, 4), parsed.value.base.?.h);
        try std.testing.expectEqual(@as(u64, 12), parsed.value.identical.?);
        try std.testing.expect(parsed.value.overhangBase == null);
        try std.testing.expect(parsed.value.overhangComp == null);
    }

    for ([_][]const []const u8{
        &.{ p_base, p_comp, "--no-diff-image", "-c", "0:0-6:5", "--json" },
        &.{ p_base, p_comp, "--no-diff-image", "-c", "0:0-5:6", "--json" },
        &.{ p_base, p_small, "--no-diff-image", "-c", "0:0-4:4", "--json" },
    }) |oob_args| {
        const res = try runOkdiff(alloc, io, oob_args);
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        try expectExited(res, 2);
        try std.testing.expectEqualStrings("", res.stdout);
        try std.testing.expect(std.mem.indexOf(u8, res.stderr, "CropOutOfBounds") != null);
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.bin_path, "--server" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    var out_buf: [8192]u8 = undefined;
    var out_reader = child.stdout.?.reader(io, &out_buf);

    {
        const Req = struct {
            requestId: u64 = 1,
            base: []const u8,
            comp: []const u8,
            crop: struct { x1: u32, y1: u32, x2: u32, y2: u32 } = .{ .x1 = 1, .y1 = 2, .x2 = 4, .y2 = 4 },
            diffLines: bool = true,
            diffCols: bool = true,
        };
        const req_json = try std.json.Stringify.valueAlloc(alloc, Req{ .base = p_base, .comp = p_comp }, .{});
        defer alloc.free(req_json);
        const req = try std.fmt.allocPrint(alloc, "{s}\n", .{req_json});
        defer alloc.free(req);
        try child.stdin.?.writeStreamingAll(io, req);
        const resp = try readServerLine(&out_reader.interface);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, resp, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u32, 4), parsed.value.base.?.w);
        try std.testing.expectEqual(@as(u32, 3), parsed.value.base.?.h);
        try std.testing.expectEqual(@as(u64, 11), parsed.value.identical.?);
        try std.testing.expectEqual(@as(u64, 1), parsed.value.nonidentical.?);
        try std.testing.expectEqualSlices(u32, &.{1}, parsed.value.diffLines.?);
        try std.testing.expectEqualSlices(u32, &.{1}, parsed.value.diffCols.?);
    }

    {
        const Req = struct {
            requestId: u64 = 2,
            base: []const u8,
            comp: []const u8,
            crop: struct { x1: u32, y1: u32, x2: u32, y2: u32 } = .{ .x1 = 0, .y1 = 0, .x2 = 9, .y2 = 2 },
        };
        const req_json = try std.json.Stringify.valueAlloc(alloc, Req{ .base = p_base, .comp = p_comp }, .{});
        defer alloc.free(req_json);
        const req = try std.fmt.allocPrint(alloc, "{s}\n", .{req_json});
        defer alloc.free(req);
        try child.stdin.?.writeStreamingAll(io, req);
        const resp = try readServerLine(&out_reader.interface);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, resp, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("CropOutOfBounds", parsed.value.@"error".?);
    }

    {
        const Req = struct {
            requestId: u64 = 3,
            base: []const u8,
            comp: []const u8,
            crop: struct { x1: u32, y1: u32, x2: u32, y2: u32 } = .{ .x1 = 3, .y1 = 1, .x2 = 1, .y2 = 2 },
        };
        const req_json = try std.json.Stringify.valueAlloc(alloc, Req{ .base = p_base, .comp = p_comp }, .{});
        defer alloc.free(req_json);
        const req = try std.fmt.allocPrint(alloc, "{s}\n", .{req_json});
        defer alloc.free(req);
        try child.stdin.?.writeStreamingAll(io, req);
        const resp = try readServerLine(&out_reader.interface);
        const parsed = try std.json.parseFromSlice(PairJson, alloc, resp, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("InvalidRegion", parsed.value.@"error".?);
    }

    try child.stdin.?.writeStreamingAll(io, "{\"command\":\"close\"}\n");
    child.stdin.?.close(io);
    child.stdin = null;
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}
