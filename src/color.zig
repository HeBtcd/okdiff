const std = @import("std");

pub const Metric = enum { oklab, yiq };

pub fn parseMetric(name: []const u8) ?Metric {
    if (std.mem.eql(u8, name, "oklab")) return .oklab;
    if (std.mem.eql(u8, name, "yiq")) return .yiq;
    return null;
}

pub const OKLAB_MAX_DELTA2: f32 = 1.0;
pub const YIQ_MAX_DELTA2: f32 = 35215.0;

const LN2: f32 = 0.6931471805599453;
const INV_LN2_2: f32 = 2.0 / 0.6931471805599453;

fn exp2v(comptime N: usize, x: @Vector(N, f32)) @Vector(N, f32) {
    const i_f = @floor(x);
    var i: @Vector(N, i32) = @intFromFloat(i_f);
    i = @max(i, @as(@Vector(N, i32), @splat(-126)));
    const r = x - @as(@Vector(N, f32), @floatFromInt(i));

    var p: @Vector(N, f32) = @splat(1.5252733804059841e-5);
    p = p * r + @as(@Vector(N, f32), @splat(0.00015403530393381608));
    p = p * r + @as(@Vector(N, f32), @splat(0.0013333558146428443));
    p = p * r + @as(@Vector(N, f32), @splat(0.009618129107628477));
    p = p * r + @as(@Vector(N, f32), @splat(0.05550410866482158));
    p = p * r + @as(@Vector(N, f32), @splat(0.2402265069591007));
    p = p * r + @as(@Vector(N, f32), @splat(LN2));
    p = p * r + @as(@Vector(N, f32), @splat(1.0));

    const scale_bits: @Vector(N, u32) = @bitCast((i + @as(@Vector(N, i32), @splat(127))) << @splat(23));
    const scale: @Vector(N, f32) = @bitCast(scale_bits);
    return p * scale;
}

fn log2v(comptime N: usize, x: @Vector(N, f32)) @Vector(N, f32) {
    const bits: @Vector(N, u32) = @bitCast(x);
    const e_bits: @Vector(N, i32) = @bitCast(bits >> @splat(23));
    const e = e_bits - @as(@Vector(N, i32), @splat(127));
    const m_bits = (bits & @as(@Vector(N, u32), @splat(0x7FFFFF))) | @as(@Vector(N, u32), @splat(0x3F800000));
    const m: @Vector(N, f32) = @bitCast(m_bits);

    const one: @Vector(N, f32) = @splat(1.0);
    const y = (m - one) / (m + one);
    const s = y * y;

    var p: @Vector(N, f32) = @splat(1.0 / 13.0);
    p = p * s + @as(@Vector(N, f32), @splat(1.0 / 11.0));
    p = p * s + @as(@Vector(N, f32), @splat(1.0 / 9.0));
    p = p * s + @as(@Vector(N, f32), @splat(1.0 / 7.0));
    p = p * s + @as(@Vector(N, f32), @splat(1.0 / 5.0));
    p = p * s + @as(@Vector(N, f32), @splat(1.0 / 3.0));
    p = p * s + one;

    return @as(@Vector(N, f32), @floatFromInt(e)) + y * p * @as(@Vector(N, f32), @splat(INV_LN2_2));
}

fn cbrtv(comptime N: usize, x: @Vector(N, f32)) @Vector(N, f32) {
    const bits: @Vector(N, u32) = @bitCast(x);
    const seed: @Vector(N, f32) = @bitCast(bits / @as(@Vector(N, u32), @splat(3)) + @as(@Vector(N, u32), @splat(0x2A51067F)));
    var y = seed;
    inline for (0..2) |_| {
        const y3 = y * y * y;
        y = y * (y3 + x + x) / (y3 + y3 + x);
    }
    return @select(f32, x == @as(@Vector(N, f32), @splat(0.0)), @as(@Vector(N, f32), @splat(0.0)), y);
}

fn srgbToLinearV(comptime N: usize, x: @Vector(N, f32)) @Vector(N, f32) {
    const inv255: @Vector(N, f32) = @splat(1.0 / 255.0);
    const lo = x * @as(@Vector(N, f32), @splat(1.0 / (255.0 * 12.92)));
    const base = (x * inv255 + @as(@Vector(N, f32), @splat(0.055))) * @as(@Vector(N, f32), @splat(1.0 / 1.055));
    const hi = exp2v(N, log2v(N, base) * @as(@Vector(N, f32), @splat(2.4)));
    return @select(f32, x * inv255 <= @as(@Vector(N, f32), @splat(0.04045)), lo, hi);
}

fn toLabV(comptime N: usize, px: @Vector(N, u32)) [3]@Vector(N, f32) {
    const bmask: @Vector(N, u32) = @splat(0xFF);
    const c_r: @Vector(N, f32) = @floatFromInt(px & bmask);
    const c_g: @Vector(N, f32) = @floatFromInt((px >> @splat(8)) & bmask);
    const c_b: @Vector(N, f32) = @floatFromInt((px >> @splat(16)) & bmask);
    const c_a: @Vector(N, f32) = @floatFromInt(px >> @splat(24));

    const alpha = c_a * @as(@Vector(N, f32), @splat(1.0 / 255.0));
    const white: @Vector(N, f32) = @splat(255.0);
    const br = white + (c_r - white) * alpha;
    const bg = white + (c_g - white) * alpha;
    const bb = white + (c_b - white) * alpha;

    const lr = srgbToLinearV(N, br);
    const lg = srgbToLinearV(N, bg);
    const lb = srgbToLinearV(N, bb);

    const l_ = cbrtv(N, lr * @as(@Vector(N, f32), @splat(0.4122214708)) +
        lg * @as(@Vector(N, f32), @splat(0.5363325363)) +
        lb * @as(@Vector(N, f32), @splat(0.0514459929)));
    const m_ = cbrtv(N, lr * @as(@Vector(N, f32), @splat(0.2119034982)) +
        lg * @as(@Vector(N, f32), @splat(0.6806995451)) +
        lb * @as(@Vector(N, f32), @splat(0.1073969566)));
    const s_ = cbrtv(N, lr * @as(@Vector(N, f32), @splat(0.0883024619)) +
        lg * @as(@Vector(N, f32), @splat(0.2817188376)) +
        lb * @as(@Vector(N, f32), @splat(0.6299787005)));

    return .{
        l_ * @as(@Vector(N, f32), @splat(0.2104542553)) +
            m_ * @as(@Vector(N, f32), @splat(0.793617785)) -
            s_ * @as(@Vector(N, f32), @splat(0.0040720468)),
        l_ * @as(@Vector(N, f32), @splat(1.9779984951)) -
            m_ * @as(@Vector(N, f32), @splat(2.428592205)) +
            s_ * @as(@Vector(N, f32), @splat(0.4505937099)),
        l_ * @as(@Vector(N, f32), @splat(0.0259040371)) +
            m_ * @as(@Vector(N, f32), @splat(0.7827717662)) -
            s_ * @as(@Vector(N, f32), @splat(0.808675766)),
    };
}

pub fn deltaE2OklabV(comptime N: usize, pa: @Vector(N, u32), pb: @Vector(N, u32)) @Vector(N, f32) {
    const a = toLabV(N, pa);
    const b = toLabV(N, pb);
    const dl = a[0] - b[0];
    const da = a[1] - b[1];
    const db = a[2] - b[2];
    return dl * dl + da * da + db * db;
}

pub fn deltaE2YiqV(comptime N: usize, pa: @Vector(N, u32), pb: @Vector(N, u32)) @Vector(N, f32) {
    const bmask: @Vector(N, u32) = @splat(0xFF);
    const white: @Vector(N, f32) = @splat(255.0);

    const ya, const ia, const qa = yiqOf(N, pa, bmask, white);
    const yb, const ib, const qb = yiqOf(N, pb, bmask, white);

    const dy = ya - yb;
    const di = ia - ib;
    const dq = qa - qb;
    return dy * dy * @as(@Vector(N, f32), @splat(0.5053)) +
        di * di * @as(@Vector(N, f32), @splat(0.299)) +
        dq * dq * @as(@Vector(N, f32), @splat(0.1957));
}

fn yiqOf(comptime N: usize, px: @Vector(N, u32), bmask: @Vector(N, u32), white: @Vector(N, f32)) struct { @Vector(N, f32), @Vector(N, f32), @Vector(N, f32) } {
    const c_r: @Vector(N, f32) = @floatFromInt(px & bmask);
    const c_g: @Vector(N, f32) = @floatFromInt((px >> @splat(8)) & bmask);
    const c_b: @Vector(N, f32) = @floatFromInt((px >> @splat(16)) & bmask);
    const c_a: @Vector(N, f32) = @floatFromInt(px >> @splat(24));
    const alpha = c_a * @as(@Vector(N, f32), @splat(1.0 / 255.0));
    const r = white + (c_r - white) * alpha;
    const g = white + (c_g - white) * alpha;
    const b = white + (c_b - white) * alpha;
    return .{
        r * @as(@Vector(N, f32), @splat(0.29889531)) + g * @as(@Vector(N, f32), @splat(0.58662247)) + b * @as(@Vector(N, f32), @splat(0.11448223)),
        r * @as(@Vector(N, f32), @splat(0.59597799)) - g * @as(@Vector(N, f32), @splat(0.27417610)) - b * @as(@Vector(N, f32), @splat(0.32180189)),
        r * @as(@Vector(N, f32), @splat(0.21147017)) - g * @as(@Vector(N, f32), @splat(0.52261711)) + b * @as(@Vector(N, f32), @splat(0.31114694)),
    };
}

pub fn deltaE2V(comptime N: usize, metric: Metric, pa: @Vector(N, u32), pb: @Vector(N, u32)) @Vector(N, f32) {
    return switch (metric) {
        .oklab => deltaE2OklabV(N, pa, pb),
        .yiq => deltaE2YiqV(N, pa, pb),
    };
}

pub fn maxDelta2(metric: Metric) f32 {
    return switch (metric) {
        .oklab => OKLAB_MAX_DELTA2,
        .yiq => YIQ_MAX_DELTA2,
    };
}

pub inline fn blendWhiteEq(pa: u32, pb: u32) bool {
    if (pa == pb) return true;
    const aa: i32 = @intCast(pa >> 24);
    const ab: i32 = @intCast(pb >> 24);
    inline for (.{ 0, 8, 16 }) |shift| {
        const ca: i32 = @intCast((pa >> shift) & 0xFF);
        const cb: i32 = @intCast((pb >> shift) & 0xFF);
        if ((ca - 255) * aa != (cb - 255) * ab) return false;
    }
    return true;
}


fn srgbToLinearS(c: f64) f64 {
    const x = c / 255.0;
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
}

fn blendChannelS(c: f64, a: f64) f64 {
    return 255.0 + (c - 255.0) * a;
}

pub fn labOf(px: u32) [3]f64 {
    const a = @as(f64, @floatFromInt((px >> 24) & 0xFF)) / 255.0;
    const r = srgbToLinearS(blendChannelS(@floatFromInt(px & 0xFF), a));
    const g = srgbToLinearS(blendChannelS(@floatFromInt((px >> 8) & 0xFF), a));
    const b = srgbToLinearS(blendChannelS(@floatFromInt((px >> 16) & 0xFF), a));
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
    };
}

pub fn lightness(px: u32) f64 {
    return labOf(px)[0];
}

pub fn deltaE2Scalar(px_a: u32, px_b: u32) f64 {
    const a = labOf(px_a);
    const b = labOf(px_b);
    const dl = a[0] - b[0];
    const da = a[1] - b[1];
    const db = a[2] - b[2];
    return dl * dl + da * da + db * db;
}
