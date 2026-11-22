const std = @import("std");
const Image = @import("image.zig").Image;
const color = @import("color.zig");

fn hasManySiblingsWithSameColor(img: *const Image, x: u32, y: u32) bool {
    if (x > img.width - 1 or y > img.height - 1) return false;
    const x0 = if (x > 0) x - 1 else 0;
    const y0 = if (y > 0) y - 1 else 0;
    const x1 = @min(x + 1, img.width - 1);
    const y1 = @min(y + 1, img.height - 1);

    var zeroes: u32 = if (x == x0 or x == x1 or y == y0 or y == y1) 1 else 0;
    const base_color = img.readRawPixel(x, y);

    var adj_y = y0;
    while (adj_y <= y1) : (adj_y += 1) {
        var adj_x = x0;
        while (adj_x <= x1) : (adj_x += 1) {
            if (zeroes < 3 and (x != adj_x or y != adj_y)) {
                if (base_color == img.readRawPixel(adj_x, adj_y)) zeroes += 1;
            }
        }
    }
    return zeroes >= 3;
}

pub fn detect(img: *const Image, x: u32, y: u32, img2: *const Image) bool {
    const x0 = if (x > 0) x - 1 else 0;
    const y0 = if (y > 0) y - 1 else 0;
    const x1 = @min(x + 1, img.width - 1);
    const y1 = @min(y + 1, img.height - 1);

    var min_delta: f64 = 0;
    var max_delta: f64 = 0;
    var min_coord = struct { x: u32, y: u32 }{ .x = 0, .y = 0 };
    var max_coord = struct { x: u32, y: u32 }{ .x = 0, .y = 0 };
    var zeroes: u32 = if (x == x0 or x == x1 or y == y0 or y == y1) 1 else 0;

    const base_color = img.readRawPixel(x, y);
    const base_l = color.lightness(base_color);

    var adj_y = y0;
    while (adj_y <= y1) : (adj_y += 1) {
        var adj_x = x0;
        while (adj_x <= x1) : (adj_x += 1) {
            if (zeroes < 3 and (x != adj_x or y != adj_y)) {
                const adj_color = img.readRawPixel(adj_x, adj_y);
                if (adj_color == base_color) {
                    zeroes += 1;
                } else {
                    const d = color.lightness(adj_color) - base_l;
                    if (d < min_delta) {
                        min_delta = d;
                        min_coord = .{ .x = adj_x, .y = adj_y };
                    } else if (d > max_delta) {
                        max_delta = d;
                        max_coord = .{ .x = adj_x, .y = adj_y };
                    }
                }
            }
        }
    }

    if (zeroes >= 3 or min_delta == 0 or max_delta == 0) return false;

    return (hasManySiblingsWithSameColor(img, min_coord.x, min_coord.y) and
        hasManySiblingsWithSameColor(img2, min_coord.x, min_coord.y)) or
        (hasManySiblingsWithSameColor(img, max_coord.x, max_coord.y) and
            hasManySiblingsWithSameColor(img2, max_coord.x, max_coord.y));
}
