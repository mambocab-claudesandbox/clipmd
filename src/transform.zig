//! The transformation engine: scan text for URLs, apply the first matching
//! rule, and render the result as Markdown, HTML, or RTF.
//!
//! Behavior summary (per output format):
//!   - markdown: a matched URL becomes `[display](url)`; unmatched URLs are
//!     left untouched so plain text stays clean.
//!   - html / rtf: a matched URL becomes a real hyperlink showing `display`;
//!     unmatched URLs are still linkified with the URL as their own text, so
//!     the rich clipboard always has clickable links.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Writer = std.Io.Writer;
const pattern = @import("pattern.zig");
const config = @import("config.zig");
const rtf = @import("rtf.zig");

pub const Format = enum {
    md,
    html,
    rtf,

    pub fn parse(s: []const u8) ?Format {
        if (mem.eql(u8, s, "md") or mem.eql(u8, s, "markdown")) return .md;
        if (mem.eql(u8, s, "html")) return .html;
        if (mem.eql(u8, s, "rtf")) return .rtf;
        return null;
    }
};

pub const Engine = struct {
    cfg: *const config.Config,

    pub fn init(cfg: *const config.Config) Engine {
        return .{ .cfg = cfg };
    }

    /// Find the first rule whose pattern matches `url`, returning the rendered
    /// display text (caller owns it). Returns null when no rule matches.
    pub fn displayFor(self: Engine, gpa: Allocator, url: []const u8) !?[]u8 {
        for (self.cfg.rules) |rule| {
            const target = if (rule.pattern.has_scheme) url else stripScheme(url);
            const values = (try rule.pattern.match(gpa, target)) orelse continue;
            defer gpa.free(values);

            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try pattern.renderTemplate(&aw.writer, rule.template, rule.pattern, values);
            return try aw.toOwnedSlice();
        }
        return null;
    }

    /// Transform `text`, writing the result in `fmt` to `w`.
    pub fn transform(self: Engine, gpa: Allocator, w: *Writer, text: []const u8, fmt: Format) !void {
        if (fmt == .rtf) try w.writeAll(rtf.header);

        var i: usize = 0;
        while (i < text.len) {
            const span = findUrl(text, i) orelse {
                try writeLiteral(w, text[i..], fmt);
                break;
            };
            try writeLiteral(w, text[i..span.start], fmt);

            const url = text[span.start..span.end];
            const display = try self.displayFor(gpa, url);
            defer if (display) |d| gpa.free(d);

            try writeLink(w, fmt, url, display);
            i = span.end;
        }

        if (fmt == .rtf) try w.writeAll(rtf.footer);
    }

    pub const Counts = struct { matched: usize = 0, total: usize = 0 };

    /// Count URLs in `text` and how many match a rule. Used for status output.
    pub fn count(self: Engine, gpa: Allocator, text: []const u8) !Counts {
        var counts: Counts = .{};
        var i: usize = 0;
        while (findUrl(text, i)) |span| {
            counts.total += 1;
            const display = try self.displayFor(gpa, text[span.start..span.end]);
            if (display) |d| {
                counts.matched += 1;
                gpa.free(d);
            }
            i = span.end;
        }
        return counts;
    }
};

const UrlSpan = struct { start: usize, end: usize };

/// Strip a leading scheme ("http://"/"https://", case-insensitive) and an
/// optional leading "www." for the purpose of pattern matching.
pub fn stripScheme(url: []const u8) []const u8 {
    var s = url;
    if (asciiStartsWithIgnoreCase(s, "https://")) {
        s = s["https://".len..];
    } else if (asciiStartsWithIgnoreCase(s, "http://")) {
        s = s["http://".len..];
    }
    if (asciiStartsWithIgnoreCase(s, "www.")) s = s["www.".len..];
    return s;
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |c, idx| {
        if (std.ascii.toLower(haystack[idx]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

/// Find the next http/https URL at or after `from`. Trailing punctuation that
/// is usually sentence-level (".,;:!?" and closing brackets/quotes) is trimmed.
fn findUrl(text: []const u8, from: usize) ?UrlSpan {
    var search = from;
    while (search < text.len) {
        const http = mem.indexOfPos(u8, text, search, "http") orelse return null;
        const rest = text[http..];
        if (asciiStartsWithIgnoreCase(rest, "https://") or asciiStartsWithIgnoreCase(rest, "http://")) {
            var end = http;
            while (end < text.len and !isUrlTerminator(text[end])) : (end += 1) {}
            // Trim trailing punctuation.
            while (end > http and isTrailingPunct(text[end - 1])) : (end -= 1) {}
            // Require at least one character after the scheme.
            const scheme_len: usize = if (asciiStartsWithIgnoreCase(rest, "https://")) 8 else 7;
            if (end > http + scheme_len) return .{ .start = http, .end = end };
            search = http + scheme_len;
        } else {
            search = http + 4;
        }
    }
    return null;
}

fn isUrlTerminator(c: u8) bool {
    return c <= ' ' or c == '<' or c == '>' or c == '"' or c == '`' or c == '|' or c == '\\' or c == '^' or c == '{' or c == '}';
}

fn isTrailingPunct(c: u8) bool {
    return switch (c) {
        '.', ',', ';', ':', '!', '?', ')', ']', '}', '\'', '"' => true,
        else => false,
    };
}

fn writeLiteral(w: *Writer, text: []const u8, fmt: Format) !void {
    switch (fmt) {
        .md => try w.writeAll(text),
        .html => try writeHtmlEscaped(w, text),
        .rtf => try rtf.writeText(w, text),
    }
}

fn writeLink(w: *Writer, fmt: Format, url: []const u8, display: ?[]const u8) !void {
    switch (fmt) {
        .md => {
            if (display) |d| {
                try w.writeByte('[');
                try writeMarkdownText(w, d);
                try w.writeAll("](");
                try w.writeAll(url);
                try w.writeByte(')');
            } else {
                // Leave unmatched URLs untouched in plain text.
                try w.writeAll(url);
            }
        },
        .html => {
            try w.writeAll("<a href=\"");
            try writeHtmlAttr(w, url);
            try w.writeAll("\">");
            try writeHtmlEscaped(w, display orelse url);
            try w.writeAll("</a>");
        },
        .rtf => try rtf.writeLink(w, url, display orelse url),
    }
}

/// Escape the few characters that have meaning in a Markdown link label.
fn writeMarkdownText(w: *Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '[', ']' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        else => try w.writeByte(c),
    };
}

fn writeHtmlEscaped(w: *Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

fn writeHtmlAttr(w: *Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn transformAlloc(text: []const u8, fmt: Format, rules: []const u8) ![]u8 {
    var cfg = try config.parse(testing.allocator, rules);
    defer cfg.deinit();
    const engine = Engine.init(&cfg);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try engine.transform(testing.allocator, &aw.writer, text, fmt);
    return aw.toOwnedSlice();
}

test "markdown transform of matched url" {
    const out = try transformAlloc(
        "https://whatever.ticketsystem.com/ABC-123",
        .md,
        "*.ticketsystem.com/{id} => {id}",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[ABC-123](https://whatever.ticketsystem.com/ABC-123)", out);
}

test "markdown leaves unmatched url untouched" {
    const out = try transformAlloc("see https://example.com/x for info", .md, "*.ticketsystem.com/{id} => {id}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("see https://example.com/x for info", out);
}

test "url embedded in sentence with trailing period" {
    const out = try transformAlloc(
        "Fixed in https://github.com/ziglang/zig/pull/42.",
        .md,
        "github.com/{owner}/{repo}/pull/{n} => {owner}/{repo}#{n}",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Fixed in [ziglang/zig#42](https://github.com/ziglang/zig/pull/42).", out);
}

test "html transform produces hyperlink" {
    const out = try transformAlloc(
        "https://whatever.ticketsystem.com/ABC-123",
        .html,
        "*.ticketsystem.com/{id} => {id}",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "<a href=\"https://whatever.ticketsystem.com/ABC-123\">ABC-123</a>",
        out,
    );
}

test "html linkifies unmatched url with url text" {
    const out = try transformAlloc("https://example.com/x", .html, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<a href=\"https://example.com/x\">https://example.com/x</a>", out);
}

test "rtf transform wraps document and links" {
    const out = try transformAlloc(
        "https://whatever.ticketsystem.com/ABC-123",
        .rtf,
        "*.ticketsystem.com/{id} => {id}",
    );
    defer testing.allocator.free(out);
    try testing.expect(mem.startsWith(u8, out, rtf.header));
    try testing.expect(mem.endsWith(u8, out, rtf.footer));
    try testing.expect(mem.indexOf(u8, out, "HYPERLINK \"https://whatever.ticketsystem.com/ABC-123\"") != null);
    try testing.expect(mem.indexOf(u8, out, "ABC-123") != null);
}

test "html escapes literal text" {
    const out = try transformAlloc("a < b & c", .html, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a &lt; b &amp; c", out);
}

test "multiple urls in one block" {
    const out = try transformAlloc(
        "a https://x.ticketsystem.com/T1 b https://x.ticketsystem.com/T2",
        .md,
        "*.ticketsystem.com/{id} => {id}",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "a [T1](https://x.ticketsystem.com/T1) b [T2](https://x.ticketsystem.com/T2)",
        out,
    );
}

test "stripScheme normalizes" {
    try testing.expectEqualStrings("example.com/x", stripScheme("https://www.example.com/x"));
    try testing.expectEqualStrings("example.com/x", stripScheme("http://example.com/x"));
    try testing.expectEqualStrings("example.com/x", stripScheme("example.com/x"));
}
