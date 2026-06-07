//! Parse a human keybinding spec (e.g. "cmd+shift+m") into a Carbon hotkey:
//! a virtual key code plus a Carbon modifier mask.
//!
//! This is pure data and is unit tested on any platform; the macOS hotkey layer
//! consumes the result. Key codes are US-ANSI (`kVK_ANSI_*`).

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;

// Carbon modifier masks (Events.h).
pub const cmd_key: u32 = 0x0100;
pub const shift_key: u32 = 0x0200;
pub const option_key: u32 = 0x0800;
pub const control_key: u32 = 0x1000;

pub const Combo = struct {
    key_code: u32,
    modifiers: u32,
};

pub const ParseError = error{
    Empty,
    UnknownModifier,
    UnknownKey,
    MultipleKeys,
    NoKey,
};

/// Parse a spec like "cmd+shift+m", "ctrl+opt+space", "cmd+1". Case- and
/// whitespace-insensitive. Modifier aliases: cmd/command/super/win, opt/option/
/// alt, ctrl/control, shift.
pub fn parse(spec: []const u8) ParseError!Combo {
    var modifiers: u32 = 0;
    var key_code: ?u32 = null;

    var it = mem.tokenizeScalar(u8, spec, '+');
    var saw_token = false;
    while (it.next()) |raw| {
        const tok = mem.trim(u8, raw, " \t");
        if (tok.len == 0) continue;
        saw_token = true;

        if (modifierMask(tok)) |m| {
            modifiers |= m;
            continue;
        }
        // Not a modifier: it must be the key.
        const code = keyCode(tok) orelse return error.UnknownKey;
        if (key_code != null) return error.MultipleKeys;
        key_code = code;
    }

    if (!saw_token) return error.Empty;
    return .{ .key_code = key_code orelse return error.NoKey, .modifiers = modifiers };
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return ascii.eqlIgnoreCase(a, b);
}

fn modifierMask(tok: []const u8) ?u32 {
    if (eqIgnoreCase(tok, "cmd") or eqIgnoreCase(tok, "command") or
        eqIgnoreCase(tok, "super") or eqIgnoreCase(tok, "win") or eqIgnoreCase(tok, "meta"))
        return cmd_key;
    if (eqIgnoreCase(tok, "shift")) return shift_key;
    if (eqIgnoreCase(tok, "opt") or eqIgnoreCase(tok, "option") or eqIgnoreCase(tok, "alt"))
        return option_key;
    if (eqIgnoreCase(tok, "ctrl") or eqIgnoreCase(tok, "control")) return control_key;
    return null;
}

/// Map a single-character or named key to a US-ANSI virtual key code.
fn keyCode(tok: []const u8) ?u32 {
    if (tok.len == 1) return charCode(ascii.toLower(tok[0]));

    // Named keys.
    if (eqIgnoreCase(tok, "space")) return 0x31;
    if (eqIgnoreCase(tok, "return") or eqIgnoreCase(tok, "enter")) return 0x24;
    if (eqIgnoreCase(tok, "tab")) return 0x30;
    if (eqIgnoreCase(tok, "escape") or eqIgnoreCase(tok, "esc")) return 0x35;
    if (eqIgnoreCase(tok, "delete") or eqIgnoreCase(tok, "backspace")) return 0x33;
    return null;
}

fn charCode(ch: u8) ?u32 {
    return switch (ch) {
        'a' => 0x00,
        'b' => 0x0B,
        'c' => 0x08,
        'd' => 0x02,
        'e' => 0x0E,
        'f' => 0x03,
        'g' => 0x05,
        'h' => 0x04,
        'i' => 0x22,
        'j' => 0x26,
        'k' => 0x28,
        'l' => 0x25,
        'm' => 0x2E,
        'n' => 0x2D,
        'o' => 0x1F,
        'p' => 0x23,
        'q' => 0x0C,
        'r' => 0x0F,
        's' => 0x01,
        't' => 0x11,
        'u' => 0x20,
        'v' => 0x09,
        'w' => 0x0D,
        'x' => 0x07,
        'y' => 0x10,
        'z' => 0x06,
        '0' => 0x1D,
        '1' => 0x12,
        '2' => 0x13,
        '3' => 0x14,
        '4' => 0x15,
        '5' => 0x17,
        '6' => 0x16,
        '7' => 0x1A,
        '8' => 0x1C,
        '9' => 0x19,
        '-' => 0x1B,
        '=' => 0x18,
        '[' => 0x21,
        ']' => 0x1E,
        '\\' => 0x2A,
        ';' => 0x29,
        '\'' => 0x27,
        ',' => 0x2B,
        '.' => 0x2F,
        '/' => 0x2C,
        '`' => 0x32,
        else => null,
    };
}

/// The default binding when none is configured: ⌘⇧M ("Markdown").
pub const default = Combo{ .key_code = 0x2E, .modifiers = cmd_key | shift_key };
pub const default_spec = "cmd+shift+m";

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse cmd+shift+m" {
    const c = try parse("cmd+shift+m");
    try testing.expectEqual(@as(u32, 0x2E), c.key_code);
    try testing.expectEqual(cmd_key | shift_key, c.modifiers);
}

test "aliases and case/space insensitive" {
    const c = try parse("  Control + Option + T ");
    try testing.expectEqual(@as(u32, 0x11), c.key_code);
    try testing.expectEqual(control_key | option_key, c.modifiers);
}

test "named key and digit" {
    try testing.expectEqual(@as(u32, 0x31), (try parse("cmd+space")).key_code);
    try testing.expectEqual(@as(u32, 0x12), (try parse("cmd+1")).key_code);
}

test "errors" {
    try testing.expectError(error.NoKey, parse("cmd+shift"));
    try testing.expectError(error.MultipleKeys, parse("cmd+a+b"));
    try testing.expectError(error.UnknownKey, parse("cmd+f13zz"));
    try testing.expectError(error.Empty, parse("   "));
}

test "default matches default_spec" {
    try testing.expectEqual(default, try parse(default_spec));
}
