const std = @import("std");
const diff = @import("diff.zig");

pub const Meta = struct {
    stem: ?[]const u8 = null,
    request_id: ?i64 = null,
};

pub fn writeJsonStr(out: *std.Io.Writer, s: []const u8) !void {
    try out.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        else => if (c < 0x20) try out.print("\\u{x:0>4}", .{c}) else try out.writeAll(&.{c}),
    };
    try out.writeAll("\"");
}

fn writeMetaPrefix(out: *std.Io.Writer, meta: Meta) !bool {
    var wrote = false;
    if (meta.stem) |stem| {
        try out.writeAll("\"stem\":");
        try writeJsonStr(out, stem);
        wrote = true;
    }
    if (meta.request_id) |id| {
        if (wrote) try out.writeAll(",");
        try out.print("\"requestId\":{d}", .{id});
        wrote = true;
    }
    return wrote;
}

pub fn writeErrorJson(out: *std.Io.Writer, meta: Meta, msg: []const u8) !void {
    try out.writeAll("{");
    if (try writeMetaPrefix(out, meta)) try out.writeAll(",");
    try out.writeAll("\"error\":");
    try writeJsonStr(out, msg);
    try out.writeAll("}");
}

pub fn writeResultJson(
    out: *std.Io.Writer,
    meta: Meta,
    base_w: u32,
    base_h: u32,
    comp_w: u32,
    comp_h: u32,
    threshold: ?f32,
    antialiasing: bool,
    r: diff.Result,
) !void {
    try out.writeAll("{");
    if (try writeMetaPrefix(out, meta)) try out.writeAll(",");
    try out.print(
        "\"base\":{{\"w\":{d},\"h\":{d}}},\"comp\":{{\"w\":{d},\"h\":{d}}},\"identical\":{d},\"nonidentical\":{d}",
        .{ base_w, base_h, comp_w, comp_h, r.identical, r.nonidentical },
    );
    if (r.ignored > 0) try out.print(",\"ignored\":{d},\"ignoredDiff\":{d}", .{ r.ignored, r.ignored_diff });
    if (threshold) |t| try out.print(",\"threshold\":{d},\"overThreshold\":{d}", .{ t, r.over_threshold });
    if (antialiasing) try out.print(",\"aaLike\":{d}", .{r.aa_like});
    if (r.overhang_base > 0) {
        try out.print(",\"overhangBase\":{d},\"overhangBaseOpaque\":{d}", .{ r.overhang_base, r.overhang_base_opaque });
    }
    if (r.overhang_comp > 0) {
        try out.print(",\"overhangComp\":{d},\"overhangCompOpaque\":{d}", .{ r.overhang_comp, r.overhang_comp_opaque });
    }
    if (r.lines.len > 0) try writeIntArray(out, "diffLines", r.lines);
    if (r.cols.len > 0) try writeIntArray(out, "diffCols", r.cols);
    try out.writeAll("}");
}

fn writeIntArray(out: *std.Io.Writer, name: []const u8, items: []const u32) !void {
    try out.print(",\"{s}\":[", .{name});
    for (items, 0..) |v, i| {
        if (i > 0) try out.writeAll(",");
        try out.print("{d}", .{v});
    }
    try out.writeAll("]");
}

pub fn writeResultText(
    out: *std.Io.Writer,
    stem: []const u8,
    base_w: u32,
    base_h: u32,
    comp_w: u32,
    comp_h: u32,
    threshold: ?f32,
    antialiasing: bool,
    r: diff.Result,
) !void {
    try out.print("{s} base={d}x{d} comp={d}x{d} identical={d} nonidentical={d}", .{
        stem, base_w, base_h, comp_w, comp_h, r.identical, r.nonidentical,
    });
    if (r.ignored > 0) try out.print(" ignored={d}({d}diff)", .{ r.ignored, r.ignored_diff });
    if (threshold) |t| try out.print(" overThreshold(t={d})={d}", .{ t, r.over_threshold });
    if (antialiasing) try out.print(" aaLike={d}", .{r.aa_like});
    if (r.overhang_base > 0) try out.print(" overhangBase={d}({d}opaque)", .{ r.overhang_base, r.overhang_base_opaque });
    if (r.overhang_comp > 0) try out.print(" overhangComp={d}({d}opaque)", .{ r.overhang_comp, r.overhang_comp_opaque });
    try out.writeAll("\n");
    if (r.lines.len > 0) try writeTextList(out, "       lines: ", r.lines);
    if (r.cols.len > 0) try writeTextList(out, "       cols: ", r.cols);
}

fn writeTextList(out: *std.Io.Writer, prefix: []const u8, items: []const u32) !void {
    try out.writeAll(prefix);
    for (items, 0..) |v, i| try out.print("{s}{d}", .{ if (i > 0) ", " else "", v });
    try out.writeAll("\n");
}
