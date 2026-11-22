const std = @import("std");
const Image = @import("image.zig").Image;
const png = @import("png.zig");
const mmap_mod = @import("mmap.zig");

const LockingAllocator = struct {
    child: std.mem.Allocator,
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *LockingAllocator) void {
        while (self.locked.swap(true, .acquire)) std.Thread.yield() catch {};
    }
    fn unlock(self: *LockingAllocator) void {
        self.locked.store(false, .release);
    }

    fn allocator(self: *LockingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *LockingAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawAlloc(n, alignment, ra);
    }
    fn resizeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LockingAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawResize(buf, alignment, new_len, ret_addr);
    }
    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LockingAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn freeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LockingAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawFree(buf, alignment, ret_addr);
    }
};

pub fn loadImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Image {
    const file = try mmap_mod.open(io, path);
    defer file.close(io);
    return png.decode(allocator, file.data);
}

const LoadResult = struct {
    image: ?Image = null,
    err: ?anyerror = null,
};

pub fn loadTwoImages(
    allocator: std.mem.Allocator,
    io: std.Io,
    path_a: []const u8,
    path_b: []const u8,
) !struct { base: Image, comp: Image } {
    var locking = LockingAllocator{ .child = allocator };
    const alloc = locking.allocator();

    const Task = struct {
        alloc: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        res: *LoadResult,
        fn run(self: @This()) void {
            self.res.image = loadImage(self.alloc, self.io, self.path) catch |e| {
                self.res.err = e;
                return;
            };
        }
    };

    var ra = LoadResult{};
    var rb = LoadResult{};
    const ta = Task{ .alloc = alloc, .io = io, .path = path_a, .res = &ra };
    const tb = Task{ .alloc = alloc, .io = io, .path = path_b, .res = &rb };

    const th_b = std.Thread.spawn(.{}, Task.run, .{tb}) catch null;
    if (th_b == null) {
        tb.run();
    } else {
        ta.run();
        th_b.?.join();
    }
    if (ra.err) |e| {
        if (rb.image) |img| img.deinit(allocator);
        return e;
    }
    if (rb.err) |e| {
        if (ra.image) |img| img.deinit(allocator);
        return e;
    }
    return .{ .base = ra.image.?, .comp = rb.image.? };
}

pub fn savePng(
    allocator: std.mem.Allocator,
    io: std.Io,
    img: Image,
    path: []const u8,
    level: std.compress.flate.Compress.Options,
) !void {
    const bytes = try png.encode(allocator, img, level);
    defer allocator.free(bytes);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

pub fn saveDeltaBin(io: std.Io, deltas: []const f32, w: u32, h: u32, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], w, .little);
    std.mem.writeInt(u32, hdr[4..8], h, .little);
    try file.writeStreamingAll(io, &hdr);
    try file.writeStreamingAll(io, std.mem.sliceAsBytes(deltas));
}
