//! The macOS menu-bar application.
//!
//! The platform work — the status item + menu, the status-icon flash, the
//! Carbon global hotkey, and the config-file watcher — lives in the Swift layer
//! (`clipmd_macos.swift`), reached through `ffi.zig`. This module keeps the
//! Zig-side glue: the shared trigger action and wiring the hotkey and watcher
//! callbacks (whose contexts are threaded in explicitly rather than via
//! globals).

const std = @import("std");
const ffi = @import("ffi.zig");
const hotkey = @import("hotkey.zig");
const clipboard = @import("../clipboard.zig");
const service = @import("../service.zig");
const watcher = @import("../watcher.zig");

const idle_title: [*:0]const u8 = "⧉";

/// Everything the callbacks need. Created in `run` (which never returns), so a
/// pointer to it is valid for the process lifetime.
const AppContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    service: *service.Service,
};

/// Shared action for the menu item and the global hotkey: transform the
/// clipboard and flash the outcome in the status-item title (the Swift layer
/// reverts to the idle glyph shortly after).
fn trigger(ctx: *AppContext) void {
    const summary = clipboard.transformClipboard(ctx.io, ctx.gpa, ctx.service) catch {
        ffi.clipmd_status_flash("⚠");
        return;
    };
    ffi.clipmd_status_flash(if (summary.total == 0) "∅" else "✓");
}

/// Trigger callback handed to the Swift layer for both the menu action and the
/// Carbon hotkey (context via the pointer passed alongside it).
fn triggerCallback(user_data: ?*anyopaque) callconv(.c) void {
    trigger(ctxFrom(user_data));
}

/// Watcher callback. Runs on the main thread (the libdispatch main queue,
/// driven by the Swift layer), so it can safely re-bind the global hotkey.
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

    // Global hotkey, sharing the same trigger callback. Non-fatal if it can't
    // register.
    hotkey.install(svc.hotkey(io), triggerCallback, &ctx) catch {};

    // Watch the config dir; reload + re-bind the hotkey on change. The handler
    // runs on the main queue (during the event loop below), so re-binding is
    // safe.
    watcher.start(gpa, svc.path, &ctx, onConfigChanged);

    // Tell anyone watching stderr that the daemon is fully set up. The bats
    // tests block on this line — before it, the socket is up but the file
    // watcher may not yet be attached, which would race a config edit.
    std.debug.print("clipmd daemon ready\n", .{});

    ffi.clipmd_app_run();
}
