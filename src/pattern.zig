//! URL pattern matching with named captures.
//!
//! Patterns are a small, predictable wildcard language (not full regex, which
//! the Zig standard library does not provide). A pattern is matched against a
//! URL and may bind named captures that a display template can reference.
//!
//! Grammar:
//!   *           matches any run of characters except '/'   (not captured)
//!   {name}      matches a run of [^/?#]+                    (captured, non-empty)
//!   {name...}   matches a run of .+ (including '/')         (captured, non-empty)
//!   anything    else is matched literally
//!
//! The whole pattern is anchored: it must match the entire (normalized) URL.
//!
//! Example:
//!   pattern   *.ticketsystem.com/{id}
//!   url       https://whatever.ticketsystem.com/ABC-123
//!   captures  id = "ABC-123"

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Token = union(enum) {
    /// A literal byte that must match exactly.
    lit: u8,
    /// `*` — matches zero or more non-'/' characters.
    star,
    /// `{name}` / `{name...}` — a named capture.
    cap: Cap,
};

pub const Cap = struct {
    name: []const u8,
    /// `true` for `{name...}`: the capture may span '/' characters.
    greedy: bool,
    /// Index of this capture in the values array produced by `match`.
    index: usize,
};

pub const Pattern = struct {
    tokens: []Token,
    /// The original pattern text (aliases the input to `parse`).
    source: []const u8,
    capture_count: usize,
    /// Whether the source pattern contained an explicit "://" scheme. When it
    /// does, matching is done against the full URL; otherwise the caller is
    /// expected to strip the scheme (and leading "www.") first.
    has_scheme: bool,

    pub fn deinit(self: *Pattern, gpa: Allocator) void {
        gpa.free(self.tokens);
        self.* = undefined;
    }

    /// Parse a pattern string. `tokens` reference the bytes of `src`, so `src`
    /// must outlive the returned `Pattern`.
    pub fn parse(gpa: Allocator, src: []const u8) !Pattern {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(gpa);

        var capture_count: usize = 0;
        var i: usize = 0;
        while (i < src.len) {
            const c = src[i];
            switch (c) {
                '{' => {
                    const end = mem.indexOfScalarPos(u8, src, i + 1, '}') orelse
                        return error.UnterminatedCapture;
                    var name = src[i + 1 .. end];
                    var greedy = false;
                    if (mem.endsWith(u8, name, "...")) {
                        greedy = true;
                        name = name[0 .. name.len - 3];
                    }
                    if (name.len == 0) return error.EmptyCaptureName;
                    try tokens.append(gpa, .{ .cap = .{
                        .name = name,
                        .greedy = greedy,
                        .index = capture_count,
                    } });
                    capture_count += 1;
                    i = end + 1;
                },
                '*' => {
                    try tokens.append(gpa, .star);
                    i += 1;
                },
                else => {
                    try tokens.append(gpa, .{ .lit = c });
                    i += 1;
                },
            }
        }

        return .{
            .tokens = try tokens.toOwnedSlice(gpa),
            .source = src,
            .capture_count = capture_count,
            .has_scheme = mem.indexOf(u8, src, "://") != null,
        };
    }

    /// Attempt to match `input` against the whole pattern. On success returns a
    /// freshly allocated slice of capture values (indexed by `Cap.index`); the
    /// slices alias `input`. Returns null when the pattern does not match.
    pub fn match(self: Pattern, gpa: Allocator, input: []const u8) !?[][]const u8 {
        const values = try gpa.alloc([]const u8, self.capture_count);
        errdefer gpa.free(values);
        if (matchFrom(self.tokens, 0, input, 0, values)) return values;
        gpa.free(values);
        return null;
    }

    /// Look up a capture value by name given the values array from `match`.
    pub fn captureValue(self: Pattern, values: []const []const u8, name: []const u8) ?[]const u8 {
        for (self.tokens) |t| switch (t) {
            .cap => |cap| if (mem.eql(u8, cap.name, name)) return values[cap.index],
            else => {},
        };
        return null;
    }
};

fn capStop(ch: u8, greedy: bool) bool {
    if (greedy) return false;
    return ch == '/' or ch == '?' or ch == '#';
}

/// Backtracking matcher. Returns true if `tokens[ti..]` matches `s[si..]`
/// exactly to the end of `s`.
fn matchFrom(tokens: []const Token, ti: usize, s: []const u8, si: usize, values: [][]const u8) bool {
    if (ti == tokens.len) return si == s.len;

    switch (tokens[ti]) {
        .lit => |c| {
            if (si < s.len and s[si] == c)
                return matchFrom(tokens, ti + 1, s, si + 1, values);
            return false;
        },
        .star => {
            // `*` matches [^/]*. Try the longest run first, then back off.
            var max = si;
            while (max < s.len and s[max] != '/') : (max += 1) {}
            var j = max;
            while (true) {
                if (matchFrom(tokens, ti + 1, s, j, values)) return true;
                if (j == si) break;
                j -= 1;
            }
            return false;
        },
        .cap => |cap| {
            // Captures are non-empty (`+`). Try the longest run first.
            var max = si;
            while (max < s.len and !capStop(s[max], cap.greedy)) : (max += 1) {}
            var j = max;
            while (j > si) : (j -= 1) {
                values[cap.index] = s[si..j];
                if (matchFrom(tokens, ti + 1, s, j, values)) return true;
            }
            return false;
        },
    }
}

/// Render a display template, substituting `{name}` with capture values. `{{`
/// and `}}` produce literal braces. Unknown `{name}` references render empty.
pub fn renderTemplate(
    w: *std.Io.Writer,
    template: []const u8,
    pattern: Pattern,
    values: []const []const u8,
) !void {
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '{') {
            if (i + 1 < template.len and template[i + 1] == '{') {
                try w.writeByte('{');
                i += 2;
                continue;
            }
            const end = mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
                // Unterminated — emit the rest literally.
                try w.writeAll(template[i..]);
                break;
            };
            const name = template[i + 1 .. end];
            if (pattern.captureValue(values, name)) |v| try w.writeAll(v);
            i = end + 1;
        } else if (c == '}' and i + 1 < template.len and template[i + 1] == '}') {
            try w.writeByte('}');
            i += 2;
        } else {
            try w.writeByte(c);
            i += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectMatch(pat_src: []const u8, input: []const u8, name: []const u8, expected: []const u8) !void {
    var pat = try Pattern.parse(testing.allocator, pat_src);
    defer pat.deinit(testing.allocator);
    const values = (try pat.match(testing.allocator, input)) orelse return error.NoMatch;
    defer testing.allocator.free(values);
    const got = pat.captureValue(values, name) orelse return error.NoCapture;
    try testing.expectEqualStrings(expected, got);
}

fn expectNoMatch(pat_src: []const u8, input: []const u8) !void {
    var pat = try Pattern.parse(testing.allocator, pat_src);
    defer pat.deinit(testing.allocator);
    const values = try pat.match(testing.allocator, input);
    if (values) |v| {
        testing.allocator.free(v);
        return error.UnexpectedMatch;
    }
}

test "subdomain wildcard with capture" {
    try expectMatch("*.ticketsystem.com/{id}", "whatever.ticketsystem.com/ABC-123", "id", "ABC-123");
}

test "multiple captures" {
    var pat = try Pattern.parse(testing.allocator, "github.com/{owner}/{repo}/pull/{num}");
    defer pat.deinit(testing.allocator);
    const values = (try pat.match(testing.allocator, "github.com/ziglang/zig/pull/12345")).?;
    defer testing.allocator.free(values);
    try testing.expectEqualStrings("ziglang", pat.captureValue(values, "owner").?);
    try testing.expectEqualStrings("zig", pat.captureValue(values, "repo").?);
    try testing.expectEqualStrings("12345", pat.captureValue(values, "num").?);
}

test "capture stops at slash, query and fragment" {
    try expectMatch("example.com/{id}", "example.com/foo", "id", "foo");
    try expectNoMatch("example.com/{id}", "example.com/foo/bar");
    try expectNoMatch("example.com/{id}", "example.com/foo?x=1");
}

test "greedy capture spans slashes" {
    try expectMatch("example.com/{path...}", "example.com/a/b/c", "path", "a/b/c");
}

test "anchored full match" {
    try expectNoMatch("example.com/{id}", "example.com/foo/extra");
    try expectMatch("example.com/{id}/", "example.com/foo/", "id", "foo");
}

test "render template substitutes captures" {
    var pat = try Pattern.parse(testing.allocator, "github.com/{owner}/{repo}/pull/{num}");
    defer pat.deinit(testing.allocator);
    const values = (try pat.match(testing.allocator, "github.com/ziglang/zig/pull/42")).?;
    defer testing.allocator.free(values);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTemplate(&aw.writer, "{owner}/{repo}#{num}", pat, values);
    try testing.expectEqualStrings("ziglang/zig#42", aw.written());
}

test "render template literal braces" {
    var pat = try Pattern.parse(testing.allocator, "{x}");
    defer pat.deinit(testing.allocator);
    const values = (try pat.match(testing.allocator, "hi")).?;
    defer testing.allocator.free(values);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderTemplate(&aw.writer, "{{{x}}}", pat, values);
    try testing.expectEqualStrings("{hi}", aw.written());
}
