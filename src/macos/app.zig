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

// ---------------------------------------------------------------------------
// System Services provider ("replace selected text")
// ---------------------------------------------------------------------------

/// `malloc` a copy of `bytes` so the Swift layer can hand it to the host app
/// and `free()` it afterwards. `malloc(0)` is avoided (it may return null).
fn dupC(bytes: []const u8) ?[*]u8 {
    const raw = std.c.malloc(@max(bytes.len, 1)) orelse return null;
    const dest: [*]u8 = @ptrCast(raw);
    @memcpy(dest[0..bytes.len], bytes);
    return dest;
}

/// Render callback for the Swift Services provider. Renders the selection
/// through the live service and hands back malloc'd md/html/rtf buffers.
fn renderCallback(
    user_data: ?*anyopaque,
    input: [*]const u8,
    input_len: usize,
    out_md: *?[*]u8,
    out_md_len: *usize,
    out_html: *?[*]u8,
    out_html_len: *usize,
    out_rtf: *?[*]u8,
    out_rtf_len: *usize,
) callconv(.c) bool {
    const ctx = ctxFrom(user_data);
    const rendered = ctx.service.renderAll(ctx.io, ctx.gpa, input[0..input_len]) catch return false;
    defer ctx.gpa.free(rendered.md);
    defer ctx.gpa.free(rendered.html);
    defer ctx.gpa.free(rendered.rtf);

    const md = dupC(rendered.md) orelse return false;
    const html = dupC(rendered.html) orelse {
        std.c.free(@ptrCast(md));
        return false;
    };
    const rtf = dupC(rendered.rtf) orelse {
        std.c.free(@ptrCast(md));
        std.c.free(@ptrCast(html));
        return false;
    };

    out_md.* = md;
    out_md_len.* = rendered.md.len;
    out_html.* = html;
    out_html_len.* = rendered.html.len;
    out_rtf.* = rtf;
    out_rtf_len.* = rendered.rtf.len;
    return true;
}

/// Run as a macOS Services provider (the right-click "Transform URL to Markdown
/// link" item). Blocks in the Cocoa event loop. Launched on demand by the
/// `clipmd.app` bundle; see `src/macos/Info.plist`.
pub fn runService(gpa: std.mem.Allocator, io: std.Io, svc: *service.Service) !void {
    var ctx = AppContext{ .gpa = gpa, .io = io, .service = svc };
    ffi.clipmd_service_run(renderCallback, &ctx);
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
