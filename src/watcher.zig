//! Watch the config file's directory and invoke a callback on change.
//!
//! We watch the *directory*, not the file, because editors typically save
//! atomically (write a temp file, then rename over the original) — a watch on
//! the file's inode would go stale after the first save. Watching the directory
//! catches create/rename/close-write of the config's basename.
//!
//! Linux: inotify on a background thread.
//! macOS: a libdispatch VNODE source on the *main* queue, so the callback runs
//!        on the main thread (where it may re-bind the global hotkey). Compiled
//!        but only linkable on macOS.
//!
//! The callback and its context are supplied by the caller (dependency
//! injection) rather than hard-wired here.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Change callback. Uses the C calling convention so it can also serve directly
/// as a libdispatch event handler. Receives the caller-supplied context.
pub const OnChange = *const fn (?*anyopaque) callconv(.c) void;

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

/// Begin watching the directory containing `path`, calling `on_change(context)`
/// on each change. Best-effort: on failure the daemon keeps running without
/// hot reload.
pub fn start(gpa: Allocator, path: []const u8, context: ?*anyopaque, on_change: OnChange) void {
    const dir = dirOf(path);
    if (comptime is_linux) {
        startLinux(gpa, path, dir, context, on_change) catch |err| {
            std.log.warn("config watch disabled: {t}", .{err});
        };
    } else if (comptime is_macos) {
        startMacos(gpa, dir, context, on_change) catch |err| {
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

// ---------------------------------------------------------------------------
// macOS: libdispatch VNODE source on the main queue
// ---------------------------------------------------------------------------

const dispatch_queue_t = ?*anyopaque;
const dispatch_source_t = ?*anyopaque;
const dispatch_source_type_t = *const anyopaque;

extern var _dispatch_source_type_vnode: anyopaque;
extern var _dispatch_main_q: anyopaque;
extern fn dispatch_source_create(t: dispatch_source_type_t, handle: usize, mask: usize, queue: dispatch_queue_t) dispatch_source_t;
extern fn dispatch_source_set_event_handler_f(source: dispatch_source_t, handler: OnChange) void;
extern fn dispatch_set_context(object: ?*anyopaque, context: ?*anyopaque) void;
extern fn dispatch_resume(object: ?*anyopaque) void;

const DISPATCH_VNODE_DELETE: usize = 0x1;
const DISPATCH_VNODE_WRITE: usize = 0x2;
const DISPATCH_VNODE_EXTEND: usize = 0x4;
const DISPATCH_VNODE_RENAME: usize = 0x20;
const O_EVTONLY: c_int = 0x8000;

// Kept alive for the lifetime of the process.
var mac_source: dispatch_source_t = null;
var mac_fd: c_int = -1;

fn startMacos(gpa: Allocator, dir: []const u8, context: ?*anyopaque, on_change: OnChange) !void {
    const dir_z = try gpa.dupeZ(u8, dir);
    defer gpa.free(dir_z);

    mac_fd = std.c.open(dir_z, .{ .ACCMODE = .RDONLY, .EVTONLY = true }, @as(c_uint, 0));
    if (mac_fd < 0) return error.OpenDir;

    const mask = DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_EXTEND;
    const src = dispatch_source_create(&_dispatch_source_type_vnode, @intCast(mac_fd), mask, &_dispatch_main_q) orelse
        return error.SourceCreate;

    dispatch_set_context(src, context);
    dispatch_source_set_event_handler_f(src, on_change);
    dispatch_resume(src);
    mac_source = src;
}
