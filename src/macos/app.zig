//! The macOS menu-bar application.
//!
//! Sets up an accessory (no Dock icon) NSApplication with a status-bar item
//! whose menu can transform the clipboard, registers a global hotkey for the
//! same action, and runs the Cocoa event loop. Menu and hotkey callbacks are
//! plain C functions, so the engine and allocator are held in module globals
//! (the app is a singleton).

const std = @import("std");
const objc = @import("objc.zig");
const hotkey = @import("hotkey.zig");
const clipboard = @import("../clipboard.zig");
const transform = @import("../transform.zig");

const id = objc.id;

var g_gpa: std.mem.Allocator = undefined;
var g_engine: *const transform.Engine = undefined;
var g_status_item: id = null;

const NSApplicationActivationPolicyAccessory: c_long = 1;
const NSVariableStatusItemLength: f64 = -1.0;

/// Shared action for the menu item and the global hotkey: transform the
/// clipboard and reflect the outcome briefly in the status-item title.
fn trigger() void {
    const summary = clipboard.transformClipboard(g_gpa, g_engine.*) catch {
        setTitle("⚠");
        return;
    };
    if (summary.total == 0) {
        setTitle("∅");
    } else {
        setTitle("✓");
    }
}

fn setTitle(text: [*:0]const u8) void {
    const button = objc.msgSend(id, g_status_item, "button", .{});
    const s = objc.msgSend(id, objc.getClass("NSString"), "stringWithUTF8String:", .{text});
    _ = objc.msgSend(void, button, "setTitle:", .{s});
}

/// Objective-C method body for `-transformClipboard:`.
fn transformClipboardAction(_: id, _: objc.SEL, _: id) callconv(.c) void {
    trigger();
}

fn hotkeyFired() void {
    trigger();
}

/// Build a one-off delegate object that responds to `-transformClipboard:`.
fn makeDelegate() id {
    const cls = objc.objc_allocateClassPair(objc.getClass("NSObject"), "ClipmdDelegate", 0);
    _ = objc.class_addMethod(
        cls,
        objc.sel("transformClipboard:"),
        @ptrCast(&transformClipboardAction),
        "v@:@",
    );
    objc.objc_registerClassPair(cls);
    const obj = objc.msgSend(id, cls, "alloc", .{});
    return objc.msgSend(id, obj, "init", .{});
}

/// Run the menu-bar app. Blocks in the Cocoa event loop until the user quits.
pub fn run(gpa: std.mem.Allocator, engine: *const transform.Engine) !void {
    g_gpa = gpa;
    g_engine = engine;

    const NSApplication = objc.getClass("NSApplication");
    const app = objc.msgSend(id, NSApplication, "sharedApplication", .{});
    _ = objc.msgSend(bool, app, "setActivationPolicy:", .{NSApplicationActivationPolicyAccessory});

    // Status-bar item.
    const NSStatusBar = objc.getClass("NSStatusBar");
    const bar = objc.msgSend(id, NSStatusBar, "systemStatusBar", .{});
    g_status_item = objc.msgSend(id, bar, "statusItemWithLength:", .{NSVariableStatusItemLength});
    setTitle("⧉");

    const delegate = makeDelegate();

    // Menu.
    const menu = objc.msgSend(id, objc.msgSend(id, objc.getClass("NSMenu"), "alloc", .{}), "init", .{});

    const t_title = objc.nsString("Transform Clipboard");
    const empty_key = objc.nsString("");
    const item = objc.msgSend(id, menu, "addItemWithTitle:action:keyEquivalent:", .{
        t_title, objc.sel("transformClipboard:"), empty_key,
    });
    _ = objc.msgSend(void, item, "setTarget:", .{delegate});

    _ = objc.msgSend(void, menu, "addItem:", .{
        objc.msgSend(id, objc.getClass("NSMenuItem"), "separatorItem", .{}),
    });

    const q_title = objc.nsString("Quit clipmd");
    const q_key = objc.nsString("q");
    _ = objc.msgSend(id, menu, "addItemWithTitle:action:keyEquivalent:", .{
        q_title, objc.sel("terminate:"), q_key,
    });

    _ = objc.msgSend(void, g_status_item, "setMenu:", .{menu});

    // Global hotkey (⌘⇧M). Non-fatal if it cannot be registered.
    hotkey.install(hotkeyFired) catch {};

    objc.release(t_title);
    objc.release(empty_key);
    objc.release(q_title);
    objc.release(q_key);

    objc.msgSend(void, app, "run", .{});
}
