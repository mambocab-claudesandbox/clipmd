//! Configuration: transformation rules and settings, in ZON
//! ("Zig Object Notation"), parsed with `std.zon`.
//!
//! Example (`~/.config/clipmd/config.zon`):
//!
//!   .{
//!       .hotkey = "cmd+shift+m",
//!       .rules = .{
//!           .{ .match = "*.ticketsystem.com/{id}", .display = "{id}" },
//!           .{ .match = "github.com/{owner}/{repo}/pull/{n}", .display = "{owner}/{repo}#{n}" },
//!       },
//!   }
//!
//! `match` uses the pattern syntax in `pattern.zig`; `display` is the template,
//! referencing `{name}` captures. `hotkey` is a keybinding spec (see
//! `keybind.zig`). A malformed config is a hard error (see `parse`).

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const pattern = @import("pattern.zig");
const keybind = @import("keybind.zig");

/// The on-disk schema, deserialized by `std.zon`.
const Schema = struct {
    hotkey: []const u8 = keybind.default_spec,
    rules: []const RuleSpec = &.{},

    const RuleSpec = struct {
        match: []const u8,
        display: []const u8,
    };
};

pub const Rule = struct {
    pattern: pattern.Pattern,
    template: []const u8,
};

pub const Config = struct {
    /// Backing storage for rule patterns/templates and copied strings.
    arena: std.heap.ArenaAllocator,
    rules: []Rule,
    /// Global-hotkey spec as written (e.g. "cmd+shift+m"), for display.
    hotkey_spec: []const u8 = keybind.default_spec,
    /// The parsed, validated global hotkey.
    hotkey: keybind.Combo = keybind.default,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Built-in example configuration, also written by `clipmd config init`.
pub const example =
    \\.{
    \\    // Global hotkey (macOS). Modifiers: cmd/command/super, shift,
    \\    // opt/option/alt, ctrl/control. Key: a character or a named key
    \\    // (space, return, tab, escape, delete).
    \\    .hotkey = "cmd+shift+m",
    \\
    \\    // Each rule maps a URL `match` pattern to a `display` template.
    \\    // Pattern syntax:
    \\    //   *          any run of characters except '/'
    \\    //   {name}     a captured run of [^/?#]+
    \\    //   {name...}  a captured run that may span '/'
    \\    // The scheme (https://) and a leading "www." are ignored unless the
    \\    // pattern itself contains "://". Templates substitute {name}.
    \\    .rules = .{
    \\        // Ticket systems: show just the ticket id, keep the link.
    \\        .{ .match = "*.ticketsystem.com/{id}", .display = "{id}" },
    \\
    \\        // GitHub pull requests and issues.
    \\        .{ .match = "github.com/{owner}/{repo}/pull/{n}", .display = "{owner}/{repo}#{n}" },
    \\        .{ .match = "github.com/{owner}/{repo}/issues/{n}", .display = "{owner}/{repo}#{n}" },
    \\
    \\        // Jira-style boards.
    \\        .{ .match = "*.atlassian.net/browse/{key}", .display = "{key}" },
    \\    },
    \\}
    \\
;

/// Parse a ZON config from in-memory `text`. A blank document yields an empty
/// configuration. Any malformed input — bad ZON, an invalid hotkey, or an empty
/// pattern — is a hard error. When `err_writer` is provided, the detailed ZON
/// syntax/type error (with line:column) is written to it on `error.ParseZon`.
pub fn parse(gpa: Allocator, text: []const u8, err_writer: ?*std.Io.Writer) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    if (mem.trim(u8, text, " \t\r\n").len == 0) {
        return .{ .arena = arena, .rules = &.{} };
    }

    // Parse into a scratch arena: `std.zon.parse.free` cannot be used safely
    // here because it would try to free string fields left at their (comptime)
    // default values. We copy what we keep into `arena` and drop the rest.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const source = try sa.dupeZ(u8, text);
    var diag: std.zon.parse.Diagnostics = .{};
    const data = std.zon.parse.fromSliceAlloc(Schema, sa, source, &diag, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            if (err_writer) |w| w.print("{f}", .{diag}) catch {};
            return error.ParseZon;
        },
    };

    const combo = keybind.parse(data.hotkey) catch return error.InvalidHotkey;
    const hotkey_spec = try a.dupe(u8, data.hotkey);

    const rules = try a.alloc(Rule, data.rules.len);
    for (data.rules, 0..) |spec, i| {
        if (spec.match.len == 0) return error.EmptyPattern;
        const match = try a.dupe(u8, spec.match);
        rules[i] = .{
            .pattern = try pattern.Pattern.parse(a, match),
            .template = try a.dupe(u8, spec.display),
        };
    }

    return .{
        .arena = arena,
        .rules = rules,
        .hotkey_spec = hotkey_spec,
        .hotkey = combo,
    };
}

/// Load config from a file via the given Io. Returns `error.FileNotFound` when
/// the path does not exist (callers may treat that as an empty rule set).
pub fn load(gpa: Allocator, io: std.Io, path: []const u8, err_writer: ?*std.Io.Writer) !Config {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const text = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(text);

    return parse(gpa, text, err_writer);
}

/// An empty configuration (no rules, default hotkey).
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

test "parse rules from ZON" {
    const text =
        \\.{
        \\    .rules = .{
        \\        .{ .match = "*.ticketsystem.com/{id}", .display = "{id}" },
        \\        .{ .match = "github.com/{o}/{r}/pull/{n}", .display = "{o}/{r}#{n}" },
        \\    },
        \\}
    ;
    var cfg = try parse(testing.allocator, text, null);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 2), cfg.rules.len);
    try testing.expectEqualStrings("*.ticketsystem.com/{id}", cfg.rules[0].pattern.source);
    try testing.expectEqualStrings("{o}/{r}#{n}", cfg.rules[1].template);
}

test "blank document is empty config with default hotkey" {
    var cfg = try parse(testing.allocator, "   \n\t\n", null);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 0), cfg.rules.len);
    try testing.expectEqual(keybind.default, cfg.hotkey);
}

test "example config parses" {
    var cfg = try parse(testing.allocator, example, null);
    defer cfg.deinit();
    try testing.expect(cfg.rules.len >= 4);
}

test "hotkey is parsed and validated" {
    const text =
        \\.{ .hotkey = "ctrl+opt+t", .rules = .{ .{ .match = "x.com/{id}", .display = "{id}" } } }
    ;
    var cfg = try parse(testing.allocator, text, null);
    defer cfg.deinit();
    try testing.expectEqualStrings("ctrl+opt+t", cfg.hotkey_spec);
    try testing.expectEqual(try keybind.parse("ctrl+opt+t"), cfg.hotkey);
}

test "malformed config is a hard error" {
    // Invalid hotkey.
    try testing.expectError(error.InvalidHotkey, parse(testing.allocator,
        \\.{ .hotkey = "cmd+nope" }
    , null));
    // Not valid ZON.
    try testing.expectError(error.ParseZon, parse(testing.allocator, "this is not zon", null));
    // Unknown field.
    try testing.expectError(error.ParseZon, parse(testing.allocator,
        \\.{ .hotky = "cmd+m" }
    , null));
    // Empty pattern.
    try testing.expectError(error.EmptyPattern, parse(testing.allocator,
        \\.{ .rules = .{ .{ .match = "", .display = "x" } } }
    , null));
}
