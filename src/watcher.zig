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
//! macOS detail: the VNODE source is on the *file itself* (not its directory).
//! A dir-level source only fires when entries are added/removed, so it would
//! miss in-place writes (`cat > file`, `echo ... > file`) — common from
//! scripts and tests. Watching the file catches WRITE/EXTEND directly, and
//! when the file is atomically replaced (editor save: write tmp + rename)
//! we re-open the watch on the new inode.
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
extern fn dispatch_source_cancel(object: ?*anyopaque) void;
extern fn dispatch_set_context(object: ?*anyopaque, context: ?*anyopaque) void;
extern fn dispatch_resume(object: ?*anyopaque) void;

const DISPATCH_VNODE_DELETE: usize = 0x1;
const DISPATCH_VNODE_WRITE: usize = 0x2;
const DISPATCH_VNODE_EXTEND: usize = 0x4;
const DISPATCH_VNODE_RENAME: usize = 0x20;
const O_EVTONLY: c_int = 0x8000;

/// Persistent state for the macOS watcher. We keep two vnode sources:
///   * dir source — fires when entries in the config dir change. Catches
///     the rename-into-dir half of an atomic save (editor temp → rename).
///     The dir itself never moves, so this fd is opened once.
///   * file source — fires on in-place WRITE/EXTEND of the config file
///     (`echo > file`, `cat > file`, etc.). After an atomic save, the
///     inode is replaced, so we re-open this source whenever the dir
///     fires (or the file source itself fires DELETE/RENAME).
const MacCtx = struct {
    gpa: Allocator,
    path_z: [:0]const u8,
    user_context: ?*anyopaque,
    on_change: OnChange,
    file_source: dispatch_source_t = null,
    file_fd: c_int = -1,
};

fn startMacos(gpa: Allocator, path: []const u8, context: ?*anyopaque, on_change: OnChange) !void {
    const ctx = try gpa.create(MacCtx);
    ctx.* = .{
        .gpa = gpa,
        .path_z = try gpa.dupeZ(u8, path),
        .user_context = context,
        .on_change = on_change,
    };

    // Open a permanent watch on the parent directory. Required: it's the only
    // signal we get when a file is atomically swapped in.
    const dir_z = try gpa.dupeZ(u8, dirOf(path));
    defer gpa.free(dir_z);
    const dir_fd = std.c.open(dir_z, .{ .ACCMODE = .RDONLY, .EVTONLY = true }, @as(c_uint, 0));
    if (dir_fd < 0) return error.OpenDir;

    const dir_mask = DISPATCH_VNODE_WRITE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_EXTEND;
    const dir_src = dispatch_source_create(&_dispatch_source_type_vnode, @intCast(dir_fd), dir_mask, &_dispatch_main_q) orelse
        return error.DirSourceCreate;
    dispatch_set_context(dir_src, ctx);
    dispatch_source_set_event_handler_f(dir_src, macOnDirEvent);
    dispatch_resume(dir_src);

    // The file watch is best-effort: it's fine if the file doesn't exist yet —
    // the dir source will pick it up on the next save and we'll try to attach.
    macOpenFileSource(ctx) catch {};
}

fn macOpenFileSource(ctx: *MacCtx) !void {
    ctx.file_fd = std.c.open(ctx.path_z, .{ .ACCMODE = .RDONLY, .EVTONLY = true }, @as(c_uint, 0));
    if (ctx.file_fd < 0) return error.OpenFile;

    const mask = DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_EXTEND;
    const src = dispatch_source_create(&_dispatch_source_type_vnode, @intCast(ctx.file_fd), mask, &_dispatch_main_q) orelse {
        _ = std.c.close(ctx.file_fd);
        ctx.file_fd = -1;
        return error.SourceCreate;
    };
    dispatch_set_context(src, ctx);
    dispatch_source_set_event_handler_f(src, macOnFileEvent);
    ctx.file_source = src;
    dispatch_resume(src);
}

fn macReopenFile(ctx: *MacCtx) void {
    if (ctx.file_source) |s| {
        dispatch_source_cancel(s);
        ctx.file_source = null;
    }
    if (ctx.file_fd >= 0) {
        _ = std.c.close(ctx.file_fd);
        ctx.file_fd = -1;
    }
    macOpenFileSource(ctx) catch {};
}

fn macOnFileEvent(user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *MacCtx = @ptrCast(@alignCast(user_data.?));
    ctx.on_change(ctx.user_context);
    // The source keeps firing on the same inode for plain WRITE/EXTEND, so
    // we don't need to re-open in that case. The dir source handles the
    // atomic-save case (and will reach us if the inode was replaced).
}

fn macOnDirEvent(user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *MacCtx = @ptrCast(@alignCast(user_data.?));
    // Something in the dir changed. The config file may have been renamed
    // in via an atomic save (so our file watch is stale), or this is unrelated
    // churn. Re-open the file watch unconditionally, then fire the callback;
    // the reload itself decides whether the new file's contents parse.
    macReopenFile(ctx);
    ctx.on_change(ctx.user_context);
}
