const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const win = std.os.windows;
const is_windows = builtin.os.tag == .windows;

const Self = @This();

file: std.Io.File,
data: []const u8,
win_mapping: if (is_windows) win.HANDLE else void =
    if (is_windows) undefined else {},

const win32 = struct {
    pub const FILE_MAP_READ: win.DWORD = 4;
    pub const PAGE_READONLY: win.DWORD = 2;
    pub extern "kernel32" fn CreateFileMappingA(
        hFile: win.HANDLE,
        lpAttributes: ?*anyopaque,
        flProtect: win.DWORD,
        dwMaximumSizeHigh: win.DWORD,
        dwMaximumSizeLow: win.DWORD,
        lpName: ?win.LPCSTR,
    ) callconv(.winapi) ?win.HANDLE;
    pub extern "kernel32" fn MapViewOfFile(
        hMapping: win.HANDLE,
        dwDesiredAccess: win.DWORD,
        dwFileOffsetHigh: win.DWORD,
        dwFileOffsetLow: win.DWORD,
        dwNumberOfBytesToMap: usize,
    ) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *anyopaque) callconv(.winapi) win.BOOL;
};

pub fn open(io: std.Io, file_path: []const u8) !Self {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    errdefer file.close(io);

    const file_size = try file.length(io);
    if (file_size == 0) return error.FileEmpty;

    if (is_windows) {
        const mapping = win32.CreateFileMappingA(file.handle, null, win32.PAGE_READONLY, 0, 0, null) orelse
            return error.CreateFileMappingFailed;
        const ptr = win32.MapViewOfFile(mapping, win32.FILE_MAP_READ, 0, 0, 0) orelse {
            win.CloseHandle(mapping);
            return error.MapViewOfFileFailed;
        };
        return .{
            .file = file,
            .data = @as([*]const u8, @ptrCast(ptr))[0..file_size],
            .win_mapping = mapping,
        };
    } else {
        const ptr = try posix.mmap(null, @intCast(file_size), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
        return .{ .file = file, .data = ptr };
    }
}

pub fn close(self: Self, io: std.Io) void {
    if (is_windows) {
        _ = win32.UnmapViewOfFile(@constCast(@ptrCast(self.data.ptr)));
        win.CloseHandle(self.win_mapping);
    } else {
        posix.munmap(@alignCast(self.data));
    }
    self.file.close(io);
}
