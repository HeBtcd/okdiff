const std = @import("std");

pub const Image = extern struct {
    data: [*]u32,
    len: usize,
    width: u32,
    height: u32,

    pub fn slice(self: Image) []u32 {
        return self.data[0..self.len];
    }

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.slice());
    }

    pub inline fn readRawPixel(self: *const Image, x: u32, y: u32) u32 {
        return self.data[y * self.width + x];
    }

    pub inline fn setImgColor(self: *Image, x: u32, y: u32, color: u32) void {
        self.data[y * self.width + x] = color;
    }

    pub fn makeBlank(self: *const Image, allocator: std.mem.Allocator) !Image {
        const data = try allocator.alloc(u32, self.len);
        @memset(data, 0);
        return .{ .width = self.width, .height = self.height, .data = data.ptr, .len = data.len };
    }

    pub fn dupe(self: *const Image, allocator: std.mem.Allocator) !Image {
        const data = try allocator.dupe(u32, self.slice());
        return .{ .width = self.width, .height = self.height, .data = data.ptr, .len = data.len };
    }

    pub fn makeWithWhiteOverlay(self: *const Image, factor: f32, allocator: std.mem.Allocator) !Image {
        const data = try allocator.alloc(u32, self.len);

        const R_COEFF: u32 = 19595;
        const G_COEFF: u32 = 38469;
        const B_COEFF: u32 = 7504;
        const clamped = if (std.math.isNan(factor)) @as(f32, 0.5) else std.math.clamp(factor, @as(f32, 0.0), @as(f32, 1.0));
        const shade: u32 = @intFromFloat(clamped * 255.0);
        const inv_shade: u32 = 255 - shade;
        const white_contrib: u32 = shade * 255;

        const N = std.simd.suggestVectorLength(u32) orelse 4;
        const simd_end = (data.len / N) * N;

        const vr: @Vector(N, u32) = @splat(R_COEFF);
        const vg: @Vector(N, u32) = @splat(G_COEFF);
        const vb: @Vector(N, u32) = @splat(B_COEFF);
        const vinv: @Vector(N, u32) = @splat(inv_shade);
        const vwhite: @Vector(N, u32) = @splat(white_contrib);
        const v255: @Vector(N, u32) = @splat(255);
        const vmask: @Vector(N, u32) = @splat(0xFF);
        const valpha: @Vector(N, u32) = @splat(0xFF000000);

        var i: usize = 0;
        while (i < simd_end) : (i += N) {
            const px: @Vector(N, u32) = self.data[i..][0..N].*;
            const r = px & vmask;
            const g = (px >> @splat(8)) & vmask;
            const b = (px >> @splat(16)) & vmask;
            const lum = (r * vr + g * vg + b * vb) >> @splat(16);
            const gray = (vinv * lum + vwhite) / v255 & vmask;
            const out = valpha | gray | (gray << @splat(8)) | (gray << @splat(16));
            data[i..][0..N].* = out;
        }
        while (i < data.len) : (i += 1) {
            const px = self.data[i];
            const lum = ((px & 0xFF) * R_COEFF + ((px >> 8) & 0xFF) * G_COEFF + ((px >> 16) & 0xFF) * B_COEFF) >> 16;
            const gray = (inv_shade * lum + white_contrib) / 255;
            data[i] = 0xFF000000 | gray | (gray << 8) | (gray << 16);
        }
        return .{ .width = self.width, .height = self.height, .data = data.ptr, .len = data.len };
    }
};
