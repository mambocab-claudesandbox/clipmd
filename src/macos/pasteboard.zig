//! NSPasteboard access: read plain text, write multiple representations.
//!
//! Writing all three representations (plain markdown, HTML, RTF) lets the
//! receiving app pick the richest format it understands: a plain editor pastes
//! Markdown text, while Mail/Pages/Word paste a real clickable hyperlink.
//!
//! The actual AppKit calls live in the Swift layer (`clipmd_macos.swift`); here
//! we just marshal Zig slices across the C-ABI boundary declared in `ffi.zig`.

const std = @import("std");
const ffi = @import("ffi.zig");

/// Read the current plain-text contents of the general pasteboard. Caller owns
/// the returned memory. Returns `error.Empty` when there is no text.
pub fn readText(gpa: std.mem.Allocator) ![]u8 {
    const cstr = ffi.clipmd_pb_read_text() orelse return error.Empty;
    defer ffi.clipmd_free(@ptrCast(cstr));
    return gpa.dupe(u8, std.mem.span(cstr));
}

/// Replace the general pasteboard with the given representations.
pub fn writeRich(plain: []const u8, html: []const u8, rtf: []const u8) void {
    ffi.clipmd_pb_write_rich(
        plain.ptr,
        plain.len,
        html.ptr,
        html.len,
        rtf.ptr,
        rtf.len,
    );
}
