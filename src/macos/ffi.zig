//! The C-ABI surface implemented by the Swift macOS layer
//! (`src/macos/clipmd_macos.swift`).
//!
//! This replaces the old hand-rolled Objective-C runtime binding (`objc.zig`
//! and its `objc_msgSend` call sites): instead of poking the runtime from Zig,
//! the AppKit work lives in a small Swift file that exports plain C functions
//! via `@_cdecl`, which we declare here as `extern fn`. Zig keeps owning the
//! business logic (transform/config/service) and hands the macOS bits across
//! this boundary.
//!
//! These symbols are resolved at link time by the Swift object that `build.zig`
//! compiles with `swiftc` (macOS only). They remain undefined in the
//! `zig build check-macos` object — which is fine, since that step only does
//! semantic analysis + codegen (no link).

/// Action invoked by the Swift layer (a menu click) on the main thread. It is
/// called with the opaque context pointer passed to `clipmd_app_setup`.
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
/// `idle_title` is the initial status-item glyph. Must be called before
/// `clipmd_app_run`.
pub extern fn clipmd_app_setup(trigger: TriggerFn, ctx: ?*anyopaque, idle_title: [*:0]const u8) void;

/// Set the status-item title. Main thread only.
pub extern fn clipmd_status_set_title(text: [*:0]const u8) void;

/// Run the Cocoa event loop. Does not return until the app terminates.
pub extern fn clipmd_app_run() void;
