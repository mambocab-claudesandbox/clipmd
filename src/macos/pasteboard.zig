//! NSPasteboard access: read plain text, write multiple representations.
//!
//! Writing all three representations (plain markdown, HTML, RTF) lets the
//! receiving app pick the richest format it understands: a plain editor pastes
//! Markdown text, while Mail/Pages/Word paste a real clickable hyperlink.

const std = @import("std");
const objc = @import("objc.zig");
const id = objc.id;

// Pasteboard UTI type strings. Using the literals avoids depending on the
// AppKit `NSPasteboardType*` extern globals.
const type_plain = "public.utf8-plain-text";
const type_html = "public.html";
const type_rtf = "public.rtf";

/// Read the current plain-text contents of the general pasteboard. Caller owns
/// the returned memory. Returns `error.Empty` when there is no text.
pub fn readText(gpa: std.mem.Allocator) ![]u8 {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const pb = objc.msgSend(id, objc.getClass("NSPasteboard"), "generalPasteboard", .{});
    const nsstr = objc.msgSend(id, pb, "stringForType:", .{objc.nsString(type_plain)});
    if (nsstr == null) return error.Empty;

    // Copied out before the pool drains the autoreleased string/buffer.
    const cstr = objc.msgSend([*:0]const u8, nsstr, "UTF8String", .{});
    return gpa.dupe(u8, std.mem.span(cstr));
}

/// Replace the general pasteboard with the given representations.
pub fn writeRich(plain: []const u8, html: []const u8, rtf: []const u8) void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const pb = objc.msgSend(id, objc.getClass("NSPasteboard"), "generalPasteboard", .{});

    const t_plain = objc.nsString(type_plain);
    const t_html = objc.nsString(type_html);
    const t_rtf = objc.nsString(type_rtf);

    var types = [_]id{ t_plain, t_html, t_rtf };
    const arr = objc.msgSend(id, objc.getClass("NSArray"), "arrayWithObjects:count:", .{
        @as([*]const id, &types),
        @as(usize, types.len),
    });
    _ = objc.msgSend(c_long, pb, "declareTypes:owner:", .{ arr, @as(id, null) });

    _ = objc.msgSend(bool, pb, "setString:forType:", .{ objc.nsString(plain), t_plain });
    _ = objc.msgSend(bool, pb, "setData:forType:", .{ objc.nsData(html), t_html });
    _ = objc.msgSend(bool, pb, "setData:forType:", .{ objc.nsData(rtf), t_rtf });
}
