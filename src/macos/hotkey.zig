//! Global hotkey registration via the Carbon Event Manager.
//!
//! `RegisterEventHotKey` provides a system-wide hotkey that, unlike an
//! `NSEvent` global monitor, does not require Accessibility permissions. The
//! key combination is configurable (see `keybind.zig`).

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
extern fn NewEventHandlerUPP(proc: EventHandlerProcPtr) EventHandlerProcPtr;
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

const kEventClassKeyboard: u32 = fourCC("keyb");
const kEventHotKeyPressed: u32 = 6;

fn fourCC(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

var on_fire: ?*const fn () void = null;
var hotkey_ref: EventHotKeyRef = null;

fn handler(_: EventHandlerCallRef, _: EventRef, _: ?*anyopaque) callconv(.c) OSStatus {
    if (on_fire) |cb| cb();
    return 0; // noErr
}

/// Install the global hotkey handler and register `combo`. `callback` runs on
/// the main thread each time the hotkey fires.
pub fn install(combo: keybind.Combo, callback: *const fn () void) !void {
    on_fire = callback;

    const spec = EventTypeSpec{
        .event_class = kEventClassKeyboard,
        .event_kind = kEventHotKeyPressed,
    };
    if (InstallEventHandler(GetApplicationEventTarget(), handler, 1, @ptrCast(&spec), null, null) != 0)
        return error.InstallHandlerFailed;

    const hk_id = EventHotKeyID{ .signature = fourCC("clpm"), .id = 1 };
    if (RegisterEventHotKey(combo.key_code, combo.modifiers, hk_id, GetApplicationEventTarget(), 0, &hotkey_ref) != 0)
        return error.RegisterHotKeyFailed;
}
