//! Global hotkey registration.
//!
//! The Carbon Event Manager machinery (`RegisterEventHotKey` and friends) now
//! lives in the Swift layer (`clipmd_macos.swift`); this module is a thin Zig
//! wrapper that translates a parsed `keybind.Combo` into the C-ABI calls and
//! maps failures back to Zig errors. A Carbon hotkey is system-wide and, unlike
//! an `NSEvent` global monitor, needs no Accessibility permission.

const keybind = @import("../keybind.zig");
const ffi = @import("ffi.zig");

/// Fire callback (C ABI), invoked on the main thread each time the hotkey fires
/// with the context passed to `install`.
pub const FireFn = ffi.TriggerFn;

/// Install the Carbon event handler (once) and register `combo`. `fire` runs on
/// the main thread each time the hotkey fires, receiving `context`.
pub fn install(combo: keybind.Combo, fire: FireFn, context: ?*anyopaque) !void {
    if (!ffi.clipmd_hotkey_install(combo.key_code, combo.modifiers, fire, context))
        return error.RegisterHotKeyFailed;
}

/// (Re-)bind the global hotkey to `combo`, unregistering any previous binding.
/// Safe to call repeatedly (e.g. after a config reload). Main thread only.
pub fn setHotKey(combo: keybind.Combo) !void {
    if (!ffi.clipmd_hotkey_set(combo.key_code, combo.modifiers))
        return error.RegisterHotKeyFailed;
}
