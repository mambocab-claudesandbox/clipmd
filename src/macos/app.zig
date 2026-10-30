//! The macOS menu-bar application.
//!
//! Sets up an accessory (no Dock icon) NSApplication with a status-bar item
//! whose menu transforms the clipboard, registers a configurable global hotkey,
//! starts the config file watcher, and runs the Cocoa event loop.
//!
//! The AppKit object work — building the status item, the menu, and running the
//! event loop — lives in the Swift layer (`clipmd_macos.swift`), reached through
//! the C-ABI functions in `ffi.zig`. This module keeps the Zig-side glue: the
//! shared trigger action, the status-icon flash/auto-revert, and wiring the
//! Carbon hotkey and config watcher (whose contexts are threaded in explicitly
//! rather than via globals).

const std = @import("std");
const ffi = @import("ffi.zig");
const hotkey = @import("hotkey.zig");
const clipboard = @import("../clipboard.zig");
const service = @import("../service.zig");
const watcher = @import("../watcher.zig");

const idle_title: [*:0]const u8 = "⧉";

// libdispatch glue for the status-icon auto-revert. We schedule a
// `setTitle(idle)` on the main queue a short time after each click; a
// generation counter prevents an early revert from a previous click from
// stomping on the visible state of a fresher one.
const dispatch_queue_t = ?*anyopaque;
extern var _dispatch_main_q: anyopaque;
extern fn dispatch_after_f(when: u64, queue: dispatch_queue_t, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern fn dispatch_time(when: u64, delta: i64) u64;
const DISPATCH_TIME_NOW: u64 = 0;
const revert_after_ns: i64 = 1_500_000_000;

var icon_gen: usize = 0;

/// Everything the callbacks need. Created in `run` (which never returns), so a
/// pointer to it is valid for the process lifetime.
const AppContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    service: *service.Service,
};

/// Shared action for the menu item and the global hotkey: transform the
/// clipboard and reflect the outcome briefly in the status-item title.
fn trigger(ctx: *AppContext) void {
    const summary = clipboard.transformClipboard(ctx.io, ctx.gpa, ctx.service) catch {
        flashTitle("⚠");
        return;
    };
    flashTitle(if (summary.total == 0) "∅" else "✓");
}

/// Set the status-item title and schedule it to revert to the idle glyph
/// after `revert_after_ns`. Latest click wins: each call bumps `icon_gen` and
/// the scheduled revert no-ops unless its captured generation still matches.
fn flashTitle(text: [*:0]const u8) void {
    ffi.clipmd_status_set_title(text);
    icon_gen +%= 1;
    dispatch_after_f(
        dispatch_time(DISPATCH_TIME_NOW, revert_after_ns),
        &_dispatch_main_q,
        @ptrFromInt(icon_gen),
        revertIconCallback,
    );
}

fn revertIconCallback(captured: ?*anyopaque) callconv(.c) void {
    const my_gen = @intFromPtr(captured);
    if (my_gen != icon_gen) return;
    ffi.clipmd_status_set_title(idle_title);
}

/// Menu-action callback handed to the Swift layer (context via the pointer we
/// passed to `clipmd_app_setup`).
fn triggerCallback(user_data: ?*anyopaque) callconv(.c) void {
    trigger(ctxFrom(user_data));
}

/// Carbon hotkey fire callback (context via userData).
fn hotkeyFired(user_data: ?*anyopaque) void {
    trigger(ctxFrom(user_data));
}

/// Watcher callback (context via the dispatch source). Runs on the main thread,
/// so it can safely re-bind the global hotkey.
fn onConfigChanged(user_data: ?*anyopaque) callconv(.c) void {
    const ctx = ctxFrom(user_data);
    ctx.service.reload(ctx.io) catch |err| {
        std.log.warn("config reload failed, keeping previous: {t}", .{err});
        return;
    };
    hotkey.setHotKey(ctx.service.hotkey(ctx.io)) catch {};
}

inline fn ctxFrom(ptr: ?*anyopaque) *AppContext {
    return @ptrCast(@alignCast(ptr.?));
}

/// Run the menu-bar app. Blocks in the Cocoa event loop until the user quits.
pub fn run(gpa: std.mem.Allocator, io: std.Io, svc: *service.Service) !void {
    var ctx = AppContext{ .gpa = gpa, .io = io, .service = svc };

    // Build the status item + menu in the Swift layer. The menu's transform
    // item will call `triggerCallback(&ctx)` on the main thread.
    ffi.clipmd_app_setup(triggerCallback, &ctx, idle_title);

    // Global hotkey (context via userData). Non-fatal if it can't register.
    hotkey.install(svc.hotkey(io), hotkeyFired, &ctx) catch {};

    // Watch the config dir; reload + re-bind the hotkey on change. The
    // handler runs on the main queue (during the event loop below), so
    // re-binding is safe.
    watcher.start(gpa, svc.path, &ctx, onConfigChanged);

    // Tell anyone watching stderr that the daemon is fully set up. The bats
    // tests block on this line — before it, the socket is up but the file
    // watcher may not yet be attached, which would race a config edit.
    std.debug.print("clipmd daemon ready\n", .{});

    ffi.clipmd_app_run();
}
