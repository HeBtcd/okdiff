const std = @import("std");
const flate = std.compress.flate;
const Image = @import("image.zig").Image;

const SIG = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

pub const DecodeError = error{
    BadSignature,
    Truncated,
    MissingIhdr,
    MissingIdat,
    UnsupportedCompression,
    UnsupportedFilter,
    UnsupportedInterlace,
    UnsupportedBitDepth,
    UnsupportedColorType,
    UnsupportedFilterType,
    Corrupt,
};


const Ihdr = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    interlace: u8,
};

fn channelsOf(color_type: u8) u8 {
    return switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => 0,
    };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const a32: i32 = a;
    const b32: i32 = b;
    const c32: i32 = c;
    const p = a32 + b32 - c32;
    const pa = @abs(p - a32);
    const pb = @abs(p - b32);
    const pc = @abs(p - c32);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

fn unfilter(recon: []u8, recon_buf: []u8, raw: []const u8, stride: usize, bpp: usize, height: usize) !void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const f = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 .. (y + 1) * (stride + 1)];
        const dst = recon[y * stride .. (y + 1) * stride];
        const prev: []const u8 = recon_buf[y * stride .. (y + 1) * stride];
        switch (f) {
            0 => @memcpy(dst, src),
            1 => {
                @memcpy(dst[0..bpp], src[0..bpp]);
                var x: usize = bpp;
                while (x < stride) : (x += 1) dst[x] = src[x] +% dst[x - bpp];
            },
            2 => {
                const N = std.simd.suggestVectorLength(u8) orelse 16;
                var x: usize = 0;
                while (x + N <= stride) : (x += N) {
                    const s: @Vector(N, u8) = src[x..][0..N].*;
                    const p: @Vector(N, u8) = prev[x..][0..N].*;
                    dst[x..][0..N].* = s +% p;
                }
                while (x < stride) : (x += 1) dst[x] = src[x] +% prev[x];
            },
            3 => {
                var x: usize = 0;
                while (x < stride) : (x += 1) {
                    const left: u16 = if (x >= bpp) dst[x - bpp] else 0;
                    dst[x] = src[x] +% @as(u8, @intCast((left + prev[x]) >> 1));
                }
            },
            4 => {
                var x: usize = 0;
                while (x < stride) : (x += 1) {
                    const a: u8 = if (x >= bpp) dst[x - bpp] else 0;
                    const b: u8 = prev[x];
                    const c: u8 = if (x >= bpp) prev[x - bpp] else 0;
                    dst[x] = src[x] +% paeth(a, b, c);
                }
            },
            else => return DecodeError.UnsupportedFilterType,
        }
    }
}

fn readBits(row: []const u8, index: usize, depth: u8) u8 {
    if (depth == 8) return row[index];
    const bit = index * depth;
    const byte = row[bit >> 3];
    const shift: u3 = @intCast(8 - depth - (bit & 7));
    const mask: u8 = (@as(u8, 1) << @intCast(depth)) - 1;
    return (byte >> shift) & mask;
}

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &SIG)) return DecodeError.BadSignature;

    var off: usize = 8;
    var ihdr: ?Ihdr = null;
    var plte: ?[]const u8 = null;
    var trns: ?[]const u8 = null;
    var idat = std.array_list.Managed([]const u8).init(allocator);
    defer idat.deinit();

    while (off + 12 <= data.len) {
        const len = std.mem.readInt(u32, data[off..][0..4], .big);
        const ctype = data[off + 4 ..][0..4];
        const body_end = off + 8 + len;
        if (body_end + 4 > data.len) return DecodeError.Truncated;
        const body = data[off + 8 .. body_end];
        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (len != 13) return DecodeError.Corrupt;
            ihdr = .{
                .width = std.mem.readInt(u32, body[0..4], .big),
                .height = std.mem.readInt(u32, body[4..8], .big),
                .bit_depth = body[8],
                .color_type = body[9],
                .interlace = body[12],
            };
            if (body[10] != 0) return DecodeError.UnsupportedCompression;
            if (body[11] != 0) return DecodeError.UnsupportedFilter;
        } else if (std.mem.eql(u8, ctype, "PLTE")) {
            plte = body;
        } else if (std.mem.eql(u8, ctype, "tRNS")) {
            trns = body;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat.append(body);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
        off = body_end + 4;
    }

    const h = ihdr orelse return DecodeError.MissingIhdr;
    if (h.width == 0 or h.height == 0) return DecodeError.Corrupt;
    if (h.interlace != 0) return DecodeError.UnsupportedInterlace;
    if (idat.items.len == 0) return DecodeError.MissingIdat;
    const channels = channelsOf(h.color_type);
    if (channels == 0) return DecodeError.UnsupportedColorType;
    switch (h.color_type) {
        0 => switch (h.bit_depth) {
            1, 2, 4, 8, 16 => {},
            else => return DecodeError.UnsupportedBitDepth,
        },
        3 => switch (h.bit_depth) {
            1, 2, 4, 8 => {},
            else => return DecodeError.UnsupportedBitDepth,
        },
        else => switch (h.bit_depth) {
            8, 16 => {},
            else => return DecodeError.UnsupportedBitDepth,
        },
    }

    const w: usize = h.width;
    const height: usize = h.height;
    const bits_pp = @as(usize, channels) * h.bit_depth;
    const stride = (w * bits_pp + 7) / 8;
    const bpp_filter: usize = @max(1, bits_pp / 8);

    const compressed = if (idat.items.len == 1) idat.items[0] else blk: {
        var total: usize = 0;
        for (idat.items) |s| total += s.len;
        const buf = try allocator.alloc(u8, total);
        var p: usize = 0;
        for (idat.items) |s| {
            @memcpy(buf[p .. p + s.len], s);
            p += s.len;
        }
        break :blk buf;
    };
    defer if (idat.items.len != 1) allocator.free(compressed);

    const raw_len = height * (stride + 1);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    var input_reader = std.Io.Reader.fixed(compressed);
    const dbuf = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(dbuf);
    var dec = flate.Decompress.init(&input_reader, .zlib, dbuf);
    dec.reader.readSliceAll(raw) catch return DecodeError.Corrupt;

    const recon_buf = try allocator.alloc(u8, (height + 1) * stride);
    defer allocator.free(recon_buf);
    @memset(recon_buf[0..stride], 0);
    const recon = recon_buf[stride..];
    try unfilter(recon, recon_buf, raw, stride, bpp_filter, height);

    const pixels = try allocator.alignedAlloc(u32, .of(u32), w * height);
    errdefer allocator.free(pixels);

    if (h.color_type == 6 and h.bit_depth == 8) {
        const bytes: []u8 = @ptrCast(pixels);
        @memcpy(bytes, recon);
        return .{ .width = h.width, .height = h.height, .data = pixels.ptr, .len = pixels.len };
    }

    var pal: [256]u32 = @splat(0);
    if (h.color_type == 3) {
        const pl = plte orelse return DecodeError.Corrupt;
        if (pl.len == 0 or pl.len % 3 != 0) return DecodeError.Corrupt;
        const n = @min(256, pl.len / 3);
        for (0..n) |i| {
            const a: u32 = if (trns != null and i < trns.?.len) trns.?[i] else 0xFF;
            pal[i] = (a << 24) | (@as(u32, pl[i * 3 + 2]) << 16) | (@as(u32, pl[i * 3 + 1]) << 8) | pl[i * 3];
        }
    }

    var trns_gray: u32 = 0;
    var trns_rgb = [3]u32{ 0, 0, 0 };
    if (trns) |t| {
        if (h.color_type == 0 and t.len >= 2) {
            trns_gray = std.mem.readInt(u16, t[0..2], .big);
        } else if (h.color_type == 2 and t.len >= 6) {
            trns_rgb = .{
                std.mem.readInt(u16, t[0..2], .big),
                std.mem.readInt(u16, t[2..4], .big),
                std.mem.readInt(u16, t[4..6], .big),
            };
        }
    }

    const sub_gray_max: u32 = (@as(u32, 1) << @intCast(h.bit_depth)) - 1;

    for (0..height) |y| {
        const row = recon[y * stride .. (y + 1) * stride];
        const out_row = pixels[y * w .. (y + 1) * w];
        for (0..w) |x| {
            out_row[x] = switch (h.color_type) {
                6 => blk: {
                    const s = x * 8;
                    const r: u32 = row[s];
                    const g: u32 = row[s + 2];
                    const b: u32 = row[s + 4];
                    const a: u32 = row[s + 6];
                    break :blk (a << 24) | (b << 16) | (g << 8) | r;
                },
                4 => blk: {
                    if (h.bit_depth == 8) {
                        const s = x * 2;
                        const g: u32 = row[s];
                        const a: u32 = row[s + 1];
                        break :blk (a << 24) | (g << 16) | (g << 8) | g;
                    } else {
                        const s = x * 4;
                        const g: u32 = row[s];
                        const a: u32 = row[s + 2];
                        break :blk (a << 24) | (g << 16) | (g << 8) | g;
                    }
                },
                2 => blk: {
                    if (h.bit_depth == 8) {
                        const s = x * 3;
                        var a: u32 = 0xFF;
                        if (trns != null and trns.?.len >= 6 and
                            @as(u32, row[s]) == (trns_rgb[0] >> 8) and
                            @as(u32, row[s + 1]) == (trns_rgb[1] >> 8) and
                            @as(u32, row[s + 2]) == (trns_rgb[2] >> 8)) a = 0;
                        break :blk (a << 24) | (@as(u32, row[s + 2]) << 16) | (@as(u32, row[s + 1]) << 8) | row[s];
                    } else {
                        const s = x * 6;
                        const r16 = std.mem.readInt(u16, row[s..][0..2], .big);
                        const g16 = std.mem.readInt(u16, row[s + 2 ..][0..2], .big);
                        const b16 = std.mem.readInt(u16, row[s + 4 ..][0..2], .big);
                        var a: u32 = 0xFF;
                        if (trns != null and trns.?.len >= 6 and
                            r16 == trns_rgb[0] and g16 == trns_rgb[1] and b16 == trns_rgb[2]) a = 0;
                        break :blk (a << 24) | (@as(u32, row[s + 4]) << 16) | (@as(u32, row[s + 2]) << 8) | row[s];
                    }
                },
                3 => pal[readBits(row, x, h.bit_depth)],
                else => blk: {
                    if (h.bit_depth == 8) {
                        const g: u32 = row[x];
                        var a: u32 = 0xFF;
                        if (trns != null and g == (trns_gray >> 8)) a = 0;
                        break :blk (a << 24) | (g << 16) | (g << 8) | g;
                    } else if (h.bit_depth == 16) {
                        const s = x * 2;
                        const g16 = std.mem.readInt(u16, row[s..][0..2], .big);
                        var a: u32 = 0xFF;
                        if (trns != null and g16 == trns_gray) a = 0;
                        const g: u32 = row[s];
                        break :blk (a << 24) | (g << 16) | (g << 8) | g;
                    } else {
                        const v: u32 = readBits(row, x, h.bit_depth);
                        const g = v * 255 / sub_gray_max;
                        var a: u32 = 0xFF;
                        if (trns != null and v == trns_gray) a = 0;
                        break :blk (a << 24) | (g << 16) | (g << 8) | g;
                    }
                },
            };
        }
    }

    return .{ .width = h.width, .height = h.height, .data = pixels.ptr, .len = pixels.len };
}


fn writeChunk(out: *std.array_list.Managed(u8), ctype: *const [4]u8, body: []const u8) !void {
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(body.len), .big);
    hdr[4..8].* = ctype.*;
    try out.appendSlice(&hdr);
    try out.appendSlice(body);
    var crc = std.hash.Crc32.init();
    crc.update(hdr[4..8]);
    crc.update(body);
    var cbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &cbuf, crc.final(), .big);
    try out.appendSlice(&cbuf);
}

pub fn encode(allocator: std.mem.Allocator, img: Image, level: flate.Compress.Options) ![]u8 {
    const stride = @as(usize, img.width) * 4;
    const raw_len = @as(usize, img.height) * (stride + 1);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    const src: []const u8 = @ptrCast(img.slice());
    for (0..img.height) |y| {
        raw[y * (stride + 1)] = 0;
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], src[y * stride ..][0..stride]);
    }

    const zbuf = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(zbuf);

    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, raw_len / 4 + 4096);
    errdefer aw.deinit();

    var comp = try flate.Compress.init(&aw.writer, zbuf, .zlib, level);
    try comp.writer.writeAll(raw);
    try comp.finish();
    const zdata = aw.written();

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.ensureUnusedCapacity(8 + 25 + zdata.len + 12);
    try out.appendSlice(&SIG);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(&out, "IHDR", &ihdr);
    try writeChunk(&out, "IDAT", zdata);
    try writeChunk(&out, "IEND", &.{});

    aw.deinit();
    return out.toOwnedSlice();
}
