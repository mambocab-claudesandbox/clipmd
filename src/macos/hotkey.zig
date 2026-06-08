//! Global hotkey registration via the Carbon Event Manager.
//!
//! `RegisterEventHotKey` provides a system-wide hotkey that, unlike an
//! `NSEvent` global monitor, does not require Accessibility permissions. The
//! key combination is configurable (see `keybind.zig`) and can be re-bound at
//! runtime with `setHotKey` (used when the config hot-reloads). The fire
//! callback's context is threaded through Carbon's `userData`, not a global.

const std = @import("std");
const keybind = @import("../keybind.zig");

const OSStatus = i32;
const EventHotKeyRef = ?*anyopaque;
const EventTargetRef = ?*anyopaque;
const EventHandlerRef = ?*anyopaque;
const EventHandlerCallRef = ?*anyopaque;
const EventRef = ?*anyopaque;

const EventHotKeyID = extern struct {
    signature: u32,
    id: u32,
};

const EventTypeSpec = extern struct {
    event_class: u32,
    event_kind: u32,
};

const EventHandlerProcPtr = *const fn (EventHandlerCallRef, EventRef, ?*anyopaque) callconv(.c) OSStatus;

extern fn GetApplicationEventTarget() EventTargetRef;
extern fn InstallEventHandler(
    target: EventTargetRef,
    handler: EventHandlerProcPtr,
    num_types: u32,
    list: [*]const EventTypeSpec,
    user_data: ?*anyopaque,
    out_ref: ?*EventHandlerRef,
) OSStatus;
extern fn RegisterEventHotKey(
    hot_key_code: u32,
    hot_key_modifiers: u32,
    hot_key_id: EventHotKeyID,
    target: EventTargetRef,
    options: u32,
    out_ref: *EventHotKeyRef,
) OSStatus;
extern fn UnregisterEventHotKey(hot_key_ref: EventHotKeyRef) OSStatus;

const kEventClassKeyboard: u32 = fourCC("keyb");
const kEventHotKeyPressed: u32 = 6;

fn fourCC(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

/// Fire callback, invoked on the main thread with the context passed to
/// `install` (delivered via Carbon's `userData`).
const FireFn = *const fn (?*anyopaque) void;

var on_fire: ?FireFn = null;
var hotkey_ref: EventHotKeyRef = null;

fn handler(_: EventHandlerCallRef, _: EventRef, user_data: ?*anyopaque) callconv(.c) OSStatus {
    if (on_fire) |cb| cb(user_data);
    return 0; // noErr
}

/// Install the Carbon event handler once and register `combo`. `fire` runs on
/// the main thread each time the hotkey fires, receiving `context`.
pub fn install(combo: keybind.Combo, fire: FireFn, context: ?*anyopaque) !void {
    on_fire = fire;

    const spec = EventTypeSpec{
        .event_class = kEventClassKeyboard,
        .event_kind = kEventHotKeyPressed,
    };
    if (InstallEventHandler(GetApplicationEventTarget(), handler, 1, @ptrCast(&spec), context, null) != 0)
        return error.InstallHandlerFailed;

    try setHotKey(combo);
}

/// (Re-)bind the global hotkey to `combo`, unregistering any previous binding.
/// Safe to call repeatedly (e.g. after a config reload). Main thread only.
pub fn setHotKey(combo: keybind.Combo) !void {
    if (hotkey_ref) |ref| {
        _ = UnregisterEventHotKey(ref);
        hotkey_ref = null;
    }
    const hk_id = EventHotKeyID{ .signature = fourCC("clpm"), .id = 1 };
    if (RegisterEventHotKey(combo.key_code, combo.modifiers, hk_id, GetApplicationEventTarget(), 0, &hotkey_ref) != 0)
        return error.RegisterHotKeyFailed;
}
