//! Watch the config file's directory and invoke a callback on change.
//!
//! Linux: inotify on a background thread (implemented here in Zig).
//! macOS: handled by the Swift layer's libdispatch VNODE watcher (see
//!        `macos/clipmd_macos.swift`), reached through `clipmd_watch_start`.
//!        Its handlers run on the main queue, where the callback may re-bind
//!        the global hotkey.
//!
//! Both platforms watch the *directory* (not just the file) because editors
//! typically save atomically — write a temp file, then rename over the
//! original — so a watch on the file's inode alone would go stale after the
//! first save. The Linux path watches the directory for the renamed-in
//! basename; the macOS path keeps a directory source plus a file source.
//!
//! The callback and its context are supplied by the caller (dependency
//! injection) rather than hard-wired here.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

const ffi = if (is_macos) @import("macos/ffi.zig") else struct {};

/// Change callback. Uses the C calling convention so it can serve directly as a
/// libdispatch / Swift event handler. Receives the caller-supplied context.
pub const OnChange = *const fn (?*anyopaque) callconv(.c) void;

/// Begin watching the directory containing `path`, calling `on_change(context)`
/// on each change. Best-effort: on failure the daemon keeps running without
/// hot reload.
pub fn start(gpa: Allocator, path: []const u8, context: ?*anyopaque, on_change: OnChange) void {
    if (comptime is_linux) {
        startLinux(gpa, path, dirOf(path), context, on_change) catch |err| {
            std.log.warn("config watch disabled: {t}", .{err});
        };
    } else if (comptime is_macos) {
        startMacos(gpa, path, context, on_change) catch |err| {
            std.log.warn("config watch disabled: {t}", .{err});
        };
    }
}

fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        return if (i == 0) "/" else path[0..i];
    }
    return ".";
}

fn baseOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

// ---------------------------------------------------------------------------
// macOS: delegate to the Swift libdispatch watcher
// ---------------------------------------------------------------------------

fn startMacos(gpa: Allocator, path: []const u8, context: ?*anyopaque, on_change: OnChange) !void {
    // Swift copies the path into its own String, so a temporary is enough.
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    if (!ffi.clipmd_watch_start(path_z, on_change, context)) return error.WatchStart;
}

// ---------------------------------------------------------------------------
// Linux: inotify
// ---------------------------------------------------------------------------

const LinuxCtx = struct {
    fd: i32,
    base: []const u8,
    context: ?*anyopaque,
    on_change: OnChange,
};

fn startLinux(gpa: Allocator, path: []const u8, dir: []const u8, context: ?*anyopaque, on_change: OnChange) !void {
    const linux = std.os.linux;

    const init_rc = linux.inotify_init1(0);
    if (isErr(init_rc)) return error.InotifyInit;
    const fd: i32 = @intCast(init_rc);

    const dir_z = try gpa.dupeZ(u8, dir);
    defer gpa.free(dir_z);

    const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE;
    if (isErr(linux.inotify_add_watch(fd, dir_z, mask))) return error.InotifyAddWatch;

    const ctx = try gpa.create(LinuxCtx);
    ctx.* = .{ .fd = fd, .base = try gpa.dupe(u8, baseOf(path)), .context = context, .on_change = on_change };

    const thread = try std.Thread.spawn(.{}, linuxLoop, .{ctx});
    thread.detach();
}

fn linuxLoop(ctx: *LinuxCtx) void {
    const linux = std.os.linux;
    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const n = std.c.read(ctx.fd, &buf, buf.len);
        if (n <= 0) break;
        var off: usize = 0;
        var hit = false;
        while (off + @sizeOf(linux.inotify_event) <= @as(usize, @intCast(n))) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(buf[off..].ptr));
            if (ev.getName()) |name| {
                if (std.mem.eql(u8, name, ctx.base)) hit = true;
            }
            off += @sizeOf(linux.inotify_event) + ev.len;
        }
        if (hit) ctx.on_change(ctx.context);
    }
}

fn isErr(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}
