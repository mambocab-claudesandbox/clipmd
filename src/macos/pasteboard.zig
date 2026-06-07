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
    const NSPasteboard = objc.getClass("NSPasteboard");
    const pb = objc.msgSend(id, NSPasteboard, "generalPasteboard", .{});

    const t_plain = objc.nsString(type_plain);
    defer objc.release(t_plain);

    const nsstr = objc.msgSend(id, pb, "stringForType:", .{t_plain});
    if (nsstr == null) return error.Empty;

    const cstr = objc.msgSend([*:0]const u8, nsstr, "UTF8String", .{});
    return gpa.dupe(u8, std.mem.span(cstr));
}

/// Replace the general pasteboard with the given representations.
pub fn writeRich(plain: []const u8, html: []const u8, rtf: []const u8) void {
    const NSPasteboard = objc.getClass("NSPasteboard");
    const pb = objc.msgSend(id, NSPasteboard, "generalPasteboard", .{});

    const t_plain = objc.nsString(type_plain);
    const t_html = objc.nsString(type_html);
    const t_rtf = objc.nsString(type_rtf);
    defer objc.release(t_plain);
    defer objc.release(t_html);
    defer objc.release(t_rtf);

    var types = [_]id{ t_plain, t_html, t_rtf };
    const NSArray = objc.getClass("NSArray");
    const arr = objc.msgSend(id, NSArray, "arrayWithObjects:count:", .{
        @as([*]const id, &types),
        @as(usize, types.len),
    });

    _ = objc.msgSend(c_long, pb, "declareTypes:owner:", .{ arr, @as(id, null) });

    const s_plain = objc.nsString(plain);
    defer objc.release(s_plain);
    _ = objc.msgSend(bool, pb, "setString:forType:", .{ s_plain, t_plain });

    const d_html = objc.nsData(html);
    defer objc.release(d_html);
    _ = objc.msgSend(bool, pb, "setData:forType:", .{ d_html, t_html });

    const d_rtf = objc.nsData(rtf);
    defer objc.release(d_rtf);
    _ = objc.msgSend(bool, pb, "setData:forType:", .{ d_rtf, t_rtf });
}
