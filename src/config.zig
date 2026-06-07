//! Configuration: a list of URL transformation rules loaded from a file.
//!
//! The file format is line-oriented and hand-editable:
//!
//!   # comments start with '#'
//!   <pattern>  =>  <display template>
//!
//! Each non-blank, non-comment line is one rule. `pattern` uses the syntax in
//! `pattern.zig`; `template` is the display text, referencing `{name}` captures.
//!
//! Example:
//!   *.ticketsystem.com/{id}              => {id}
//!   github.com/{owner}/{repo}/pull/{n}   => {owner}/{repo}#{n}

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const pattern = @import("pattern.zig");

pub const Rule = struct {
    pattern: pattern.Pattern,
    template: []const u8,
};

pub const Config = struct {
    /// Backing storage for rule patterns/templates and the raw file text.
    arena: std.heap.ArenaAllocator,
    rules: []Rule,
    /// Optional global-hotkey spec (e.g. "cmd+shift+m") from `@hotkey`. Null
    /// means use the built-in default. Aliases the arena-owned text.
    hotkey: ?[]const u8 = null,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Built-in example configuration, also written by `clipmd config init`.
pub const example =
    \\# clipmd transformation rules
    \\#
    \\# Format:  <url-pattern>  =>  <display-template>
    \\#
    \\# Pattern syntax:
    \\#   *          any run of characters except '/'
    \\#   {name}     a captured run of [^/?#]+
    \\#   {name...}  a captured run that may span '/'
    \\# The scheme (https://) and a leading "www." are ignored unless the
    \\# pattern itself contains "://".
    \\#
    \\# Templates substitute {name} with the matching capture.
    \\#
    \\# Settings use `@name value`. The global hotkey (macOS) is configurable;
    \\# modifiers: cmd/command/super, shift, opt/option/alt, ctrl/control.
    \\@hotkey cmd+shift+m
    \\
    \\# Ticket systems: show just the ticket id, keep the link.
    \\*.ticketsystem.com/{id}                 => {id}
    \\
    \\# GitHub pull requests and issues.
    \\github.com/{owner}/{repo}/pull/{n}      => {owner}/{repo}#{n}
    \\github.com/{owner}/{repo}/issues/{n}    => {owner}/{repo}#{n}
    \\
    \\# Jira-style boards.
    \\*.atlassian.net/browse/{key}            => {key}
    \\
;

/// Parse rules from in-memory `text`. The returned `Config` owns a copy of the
/// text, so `text` need not outlive it.
pub fn parse(gpa: Allocator, text: []const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Copy the text so patterns/templates can safely alias it.
    const owned = try a.dupe(u8, text);

    var rules: std.ArrayList(Rule) = .empty;
    var hotkey: ?[]const u8 = null;

    var lines = mem.splitScalar(u8, owned, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Directive lines: `@name value` (e.g. `@hotkey cmd+shift+m`).
        if (line[0] == '@') {
            try parseDirective(line[1..], &hotkey);
            continue;
        }

        const arrow = mem.indexOf(u8, line, "=>") orelse return error.MissingArrow;
        const pat_src = mem.trim(u8, line[0..arrow], " \t");
        const template = mem.trim(u8, line[arrow + 2 ..], " \t");
        if (pat_src.len == 0) return error.EmptyPattern;

        const pat = try pattern.Pattern.parse(a, pat_src);
        try rules.append(a, .{ .pattern = pat, .template = template });
    }

    return .{
        .arena = arena,
        .rules = try rules.toOwnedSlice(a),
        .hotkey = hotkey,
    };
}

/// Parse a directive body (text after the leading `@`). The name runs up to the
/// first space, tab, or `=`; the value is the trimmed remainder (a leading `=`
/// is allowed). Unknown directives are ignored.
fn parseDirective(body: []const u8, hotkey: *?[]const u8) !void {
    const s = mem.trim(u8, body, " \t");
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != '=') : (end += 1) {}
    const name = s[0..end];
    const value = mem.trim(u8, s[end..], " \t=");

    if (mem.eql(u8, name, "hotkey")) {
        if (value.len == 0) return error.EmptyDirectiveValue;
        hotkey.* = value;
    }
}

/// Load rules from a file via the given Io. Returns `error.FileNotFound` when
/// the path does not exist (callers may treat that as an empty rule set).
pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !Config {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const text = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(text);

    return parse(gpa, text);
}

/// An empty configuration (no rules). Used when no config file is present.
pub fn empty(gpa: Allocator) Config {
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .rules = &.{},
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse rules and skip comments/blanks" {
    const text =
        \\# a comment
        \\
        \\*.ticketsystem.com/{id}  => {id}
        \\  github.com/{o}/{r}/pull/{n} => {o}/{r}#{n}
    ;
    var cfg = try parse(testing.allocator, text);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 2), cfg.rules.len);
    try testing.expectEqualStrings("{id}", cfg.rules[0].template);
    try testing.expectEqualStrings("{o}/{r}#{n}", cfg.rules[1].template);
}

test "missing arrow is an error" {
    try testing.expectError(error.MissingArrow, parse(testing.allocator, "just-a-pattern"));
}

test "example config parses" {
    var cfg = try parse(testing.allocator, example);
    defer cfg.deinit();
    try testing.expect(cfg.rules.len >= 4);
}

test "hotkey directive is parsed and rules still load" {
    const text =
        \\@hotkey ctrl+opt+t
        \\*.ticketsystem.com/{id} => {id}
    ;
    var cfg = try parse(testing.allocator, text);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.rules.len);
    try testing.expectEqualStrings("ctrl+opt+t", cfg.hotkey.?);
}

test "hotkey directive accepts equals form" {
    var cfg = try parse(testing.allocator, "@hotkey = cmd+1");
    defer cfg.deinit();
    try testing.expectEqualStrings("cmd+1", cfg.hotkey.?);
}
