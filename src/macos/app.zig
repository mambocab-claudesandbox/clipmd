//! The macOS menu-bar application.
//!
//! Sets up an accessory (no Dock icon) NSApplication with a status-bar item
//! whose menu transforms the clipboard, registers a configurable global hotkey,
//! starts the config file watcher, and runs the Cocoa event loop.
//!
//! Callbacks are plain C functions, but their context is threaded in explicitly
//! rather than via globals: the Carbon hotkey gets it through `userData`, the
//! menu target through the instance's indexed ivars, and the watcher through
//! libdispatch's source context.

const std = @import("std");
const objc = @import("objc.zig");
const hotkey = @import("hotkey.zig");
const clipboard = @import("../clipboard.zig");
const service = @import("../service.zig");
const watcher = @import("../watcher.zig");

const id = objc.id;

const NSApplicationActivationPolicyAccessory: c_long = 1;
const NSVariableStatusItemLength: f64 = -1.0;

/// Everything the callbacks need. Created in `run` (which never returns), so a
/// pointer to it is valid for the process lifetime.
const AppContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    service: *service.Service,
    status_item: id = null,
};

/// Shared action for the menu item and the global hotkey: transform the
/// clipboard and reflect the outcome briefly in the status-item title.
fn trigger(ctx: *AppContext) void {
    const summary = clipboard.transformClipboard(ctx.io, ctx.gpa, ctx.service) catch {
        setTitle(ctx, "⚠");
        return;
    };
    setTitle(ctx, if (summary.total == 0) "∅" else "✓");
}

fn setTitle(ctx: *AppContext, text: [*:0]const u8) void {
    const button = objc.msgSend(id, ctx.status_item, "button", .{});
    const s = objc.msgSend(id, objc.getClass("NSString"), "stringWithUTF8String:", .{text});
    objc.msgSend(void, button, "setTitle:", .{s});
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

/// Read the AppContext pointer back out of a delegate's indexed ivars. The
/// slot holds a *pointer* to the context (written by `makeDelegate`), so
/// this is a double-pointer load. Factored so the round-trip is unit-tested
/// — getting the dereference level wrong here used to silently corrupt the
/// trigger path and crash the first time the menu item was clicked.
fn ctxFromDelegate(self: id) *AppContext {
    const slot: **AppContext = @ptrCast(@alignCast(objc.object_getIndexedIvars(self).?));
    return slot.*;
}

/// Objective-C method body for `-transformClipboard:`.
fn transformClipboardAction(self: id, _: objc.SEL, _: id) callconv(.c) void {
    trigger(ctxFromDelegate(self));
}

/// Build a delegate object that responds to `-transformClipboard:` and carries
/// `ctx` in its indexed ivars. `class_name` is parameterized so tests can
/// register a separate class and avoid collisions with the production one
/// when both end up in the same process (e.g. under `zig build test`).
fn makeDelegateNamed(class_name: [*:0]const u8, ctx: *AppContext) id {
    const cls = objc.objc_allocateClassPair(objc.getClass("NSObject"), class_name, @sizeOf(*AppContext));
    _ = objc.class_addMethod(cls, objc.sel("transformClipboard:"), @ptrCast(&transformClipboardAction), "v@:@");
    objc.objc_registerClassPair(cls);

    const obj = objc.msgSend(id, objc.msgSend(id, cls, "alloc", .{}), "init", .{});
    const slot: **AppContext = @ptrCast(@alignCast(objc.object_getIndexedIvars(obj).?));
    slot.* = ctx;
    return obj;
}

fn makeDelegate(ctx: *AppContext) id {
    return makeDelegateNamed("ClipmdDelegate", ctx);
}

/// Run the menu-bar app. Blocks in the Cocoa event loop until the user quits.
pub fn run(gpa: std.mem.Allocator, io: std.Io, svc: *service.Service) !void {
    var ctx = AppContext{ .gpa = gpa, .io = io, .service = svc };
    const app = objc.msgSend(id, objc.getClass("NSApplication"), "sharedApplication", .{});

    {
        // One pool drains every transient object created during setup. The
        // menu and the delegate are alloc/init'd (so they own a +1 refcount);
        // the status item is autoreleased, so it gets an explicit retain
        // below before this pool drains.
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        _ = objc.msgSend(bool, app, "setActivationPolicy:", .{NSApplicationActivationPolicyAccessory});

        const bar = objc.msgSend(id, objc.getClass("NSStatusBar"), "systemStatusBar", .{});
        // `statusItemWithLength:` returns an *autoreleased* NSStatusItem —
        // the status bar does not retain it. Without an explicit retain it
        // would be freed when this autorelease pool drains, taking the menu
        // bar item with it and leaving every later access dangling (which
        // segfaults the Carbon hotkey handler the first time it fires).
        ctx.status_item = objc.msgSend(id, bar, "statusItemWithLength:", .{NSVariableStatusItemLength});
        _ = objc.msgSend(id, ctx.status_item, "retain", .{});
        setTitle(&ctx, "⧉");

        const delegate = makeDelegate(&ctx);

        const menu = objc.msgSend(id, objc.msgSend(id, objc.getClass("NSMenu"), "alloc", .{}), "init", .{});

        const item = objc.msgSend(id, menu, "addItemWithTitle:action:keyEquivalent:", .{
            objc.nsString("Transform Clipboard"), objc.sel("transformClipboard:"), objc.nsString(""),
        });
        objc.msgSend(void, item, "setTarget:", .{delegate});

        objc.msgSend(void, menu, "addItem:", .{
            objc.msgSend(id, objc.getClass("NSMenuItem"), "separatorItem", .{}),
        });

        _ = objc.msgSend(id, menu, "addItemWithTitle:action:keyEquivalent:", .{
            objc.nsString("Quit clipmd"), objc.sel("terminate:"), objc.nsString("q"),
        });

        objc.msgSend(void, ctx.status_item, "setMenu:", .{menu});

        // Global hotkey (context via userData). Non-fatal if it can't register.
        hotkey.install(svc.hotkey(io), hotkeyFired, &ctx) catch {};

        // Watch the config dir; reload + re-bind the hotkey on change. The
        // handler runs on the main queue (during the event loop below), so
        // re-binding is safe.
        watcher.start(gpa, svc.path, &ctx, onConfigChanged);
    }

    // Tell anyone watching stderr that the daemon is fully set up. The bats
    // tests block on this line — before it, the socket is up but the file
    // watcher may not yet be attached, which would race a config edit.
    std.debug.print("clipmd daemon ready\n", .{});

    objc.msgSend(void, app, "run", .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "delegate ivars round-trip the AppContext pointer" {
    // Regression for a menu-click crash: makeDelegate stores the AppContext
    // as a *pointer* in the indexed ivars, but transformClipboardAction was
    // casting the slot's address straight to *AppContext (one dereference
    // missing), turning every click into a use of garbage. Now that the
    // load lives in ctxFromDelegate, lock the round-trip in here.
    var fake_ctx: AppContext = undefined;
    const delegate = makeDelegateNamed("ClipmdDelegateTest", &fake_ctx);
    try testing.expectEqual(@as(*AppContext, &fake_ctx), ctxFromDelegate(delegate));
}
