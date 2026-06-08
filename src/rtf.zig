//! Minimal RTF generation for rich-text clipboard output.
//!
//! Produces an RTF document whose matched URLs are real hyperlink fields, so
//! pasting into Mail, Pages, Word, etc. yields clickable links rather than raw
//! URLs. Plain runs are written with proper RTF escaping.

const std = @import("std");
const Writer = std.Io.Writer;

/// Document preamble. Deliberately minimal: no font table, no color table, and
/// no font/size/paragraph selectors, so that when the fragment is pasted into an
/// existing document the inserted text inherits the destination's current
/// formatting. `\ansicpg1252` only declares the code page for the rare `\'hh`
/// byte-escape fallback; it imposes no visual style.
pub const header = "{\\rtf1\\ansi\\ansicpg1252 ";

pub const footer = "}";

/// Escape and write a run of UTF-8 text as RTF. ASCII passes through (with
/// `\`, `{`, `}` escaped); non-ASCII is emitted as `\uN ` unicode escapes.
pub fn writeText(w: *Writer, text: []const u8) !void {
    const view = std.unicode.Utf8View.init(text) catch {
        // Not valid UTF-8: fall back to byte-wise ASCII-safe escaping.
        for (text) |b| try writeByte(w, b);
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '\\' => try w.writeAll("\\\\"),
            '{' => try w.writeAll("\\{"),
            '}' => try w.writeAll("\\}"),
            '\n' => try w.writeAll("\\line "),
            '\r' => {},
            '\t' => try w.writeAll("\\tab "),
            else => {
                if (cp < 0x80) {
                    try w.writeByte(@intCast(cp));
                } else {
                    try writeUnicode(w, cp);
                }
            },
        }
    }
}

fn writeByte(w: *Writer, b: u8) !void {
    switch (b) {
        '\\' => try w.writeAll("\\\\"),
        '{' => try w.writeAll("\\{"),
        '}' => try w.writeAll("\\}"),
        0x20...0x5b, 0x5d...0x7a, 0x7c, 0x7e, 0x09 => try w.writeByte(b),
        else => try w.print("\\'{x:0>2}", .{b}),
    }
}

/// Emit a Unicode codepoint as an RTF `\uN ` escape. RTF uses signed 16-bit
/// values, so codepoints above 0x7FFF wrap to negative. Astral codepoints are
/// written as a surrogate pair, which is what RTF readers expect.
fn writeUnicode(w: *Writer, cp: u21) !void {
    if (cp <= 0xFFFF) {
        const signed: i32 = if (cp > 0x7FFF) @as(i32, cp) - 0x10000 else @intCast(cp);
        try w.print("\\u{d} ", .{signed});
    } else {
        const v = cp - 0x10000;
        const hi: i32 = @as(i32, 0xD800) + @as(i32, @intCast(v >> 10));
        const lo: i32 = @as(i32, 0xDC00) + @as(i32, @intCast(v & 0x3FF));
        try w.print("\\u{d} \\u{d} ", .{ hi - 0x10000, lo - 0x10000 });
    }
}

/// Write a hyperlink field: displays `text`, links to `url`. The result run is
/// left unstyled so it inherits the destination document's formatting (the URL
/// is still a real, clickable link via the field).
pub fn writeLink(w: *Writer, url: []const u8, text: []const u8) !void {
    try w.writeAll("{\\field{\\*\\fldinst{HYPERLINK \"");
    try writeUrl(w, url);
    try w.writeAll("\"}}{\\fldrslt ");
    try writeText(w, text);
    try w.writeAll("}}");
}

/// Escape a URL for use inside the HYPERLINK field instruction's quotes.
fn writeUrl(w: *Writer, url: []const u8) !void {
    for (url) |b| switch (b) {
        '\\' => try w.writeAll("\\\\"),
        '{' => try w.writeAll("\\{"),
        '}' => try w.writeAll("\\}"),
        '"' => try w.writeAll("\\\""),
        else => try w.writeByte(b),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn render(comptime f: anytype, args: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

test "escape special characters" {
    const out = try render(writeText, .{"a{b}c\\d"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\\{b\\}c\\\\d", out);
}

test "newline becomes line break" {
    const out = try render(writeText, .{"a\nb"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\\line b", out);
}

test "non-ascii becomes unicode escape" {
    const out = try render(writeText, .{"café"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("caf\\u233 ", out);
}

test "hyperlink field" {
    const out = try render(writeLink, .{ "https://x.com/1", "TICKET-1" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\\field{\\*\\fldinst{HYPERLINK \"https://x.com/1\"}}{\\fldrslt TICKET-1}}",
        out,
    );
}
