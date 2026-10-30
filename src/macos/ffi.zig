//! The C-ABI surface implemented by the Swift macOS layer
//! (`src/macos/clipmd_macos.swift`).
//!
//! This replaces the hand-rolled bindings that used to live on the Zig side:
//! the Objective-C runtime (`objc_msgSend`) for AppKit, plus the direct Carbon
//! and libdispatch `extern fn` declarations for the global hotkey, the status
//! icon flash, and the config watcher. All of that now lives in a small Swift
//! file that exports plain C functions via `@_cdecl`, declared here as
//! `extern fn`. Zig keeps owning the business logic (transform/config/service)
//! and hands the macOS bits across this boundary.
//!
//! These symbols are resolved at link time by the Swift object that `build.zig`
//! compiles with `swiftc` (macOS only). They remain undefined in the
//! `zig build check-macos` object — which is fine, since that step only does
//! semantic analysis + codegen (no link).

/// Action invoked by the Swift layer (a menu click, a hotkey press, or a config
/// change) on the main thread. It is called with the opaque context pointer
/// passed alongside it.
pub const TriggerFn = *const fn (?*anyopaque) callconv(.c) void;

// ---------------------------------------------------------------------------
// Pasteboard
// ---------------------------------------------------------------------------

/// Read the general pasteboard's plain text. Returns a `malloc`-allocated,
/// NUL-terminated UTF-8 string the caller must release with `clipmd_free`, or
/// `null` when the pasteboard holds no text.
pub extern fn clipmd_pb_read_text() ?[*:0]u8;

/// Replace the general pasteboard with the three representations. Each is a
/// byte buffer + length; a zero length skips that type.
pub extern fn clipmd_pb_write_rich(
    plain: [*]const u8,
    plain_len: usize,
    html: [*]const u8,
    html_len: usize,
    rtf: [*]const u8,
    rtf_len: usize,
) void;

/// Free a pointer returned by the Swift layer (e.g. `clipmd_pb_read_text`).
pub extern fn clipmd_free(ptr: ?*anyopaque) void;

// ---------------------------------------------------------------------------
// Menu-bar app
// ---------------------------------------------------------------------------

/// Build the accessory `NSApplication`, its status-bar item, and the menu.
/// The "Transform Clipboard" item invokes `trigger(ctx)` on the main thread.
/// `idle_title` is the resting status-item glyph (also the target the flash
/// reverts to). Must be called before `clipmd_app_run`.
pub extern fn clipmd_app_setup(trigger: TriggerFn, ctx: ?*anyopaque, idle_title: [*:0]const u8) void;

/// Flash a transient status-item title; the Swift layer reverts to the idle
/// glyph after a short delay. Latest flash wins. Main thread only.
pub extern fn clipmd_status_flash(text: [*:0]const u8) void;

/// Run the Cocoa event loop. Does not return until the app terminates.
pub extern fn clipmd_app_run() void;

// ---------------------------------------------------------------------------
// Global hotkey (Carbon, in the Swift layer)
// ---------------------------------------------------------------------------

/// Install the Carbon event handler (once) and register the hotkey. `fire(ctx)`
/// runs on the main thread each time it fires. Returns false on failure.
pub extern fn clipmd_hotkey_install(key_code: u32, modifiers: u32, fire: TriggerFn, ctx: ?*anyopaque) bool;

/// Re-bind the global hotkey, unregistering any previous binding. Main thread
/// only. Returns false on failure.
pub extern fn clipmd_hotkey_set(key_code: u32, modifiers: u32) bool;

// ---------------------------------------------------------------------------
// Config-file watcher (libdispatch VNODE source, in the Swift layer)
// ---------------------------------------------------------------------------

/// Watch `path` (and its parent directory, to catch atomic saves), calling
/// `on_change(ctx)` on the main thread for each change. Returns false if the
/// watch could not be established.
pub extern fn clipmd_watch_start(path: [*:0]const u8, on_change: TriggerFn, ctx: ?*anyopaque) bool;
