//! clipmd — transform URLs on the clipboard (or a pipe) into Markdown plus a
//! real rich-text hyperlink, driven by config-file rules.
//!
//! Subcommands:
//!   transform   read stdin, write transformed text to stdout  (default)
//!   daemon      run the background service (menu bar + global hotkey on macOS,
//!               plus a Unix socket so the CLI can drive it)
//!   clip        transform the macOS clipboard in place (one-shot)
//!   run         tell a running daemon to transform the clipboard now
//!   send        pipe stdin through a running daemon, print the result
//!   config      path | init | show
//!   version, help

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;

const transform = @import("transform.zig");
const config = @import("config.zig");
const ipc = @import("ipc.zig");
const clipboard = @import("clipboard.zig");

const is_macos = builtin.os.tag == .macos;
const app = if (is_macos) @import("macos/app.zig") else struct {};

const version = "0.1.0";

const usage =
    \\clipmd — transform clipboard/stdin URLs into Markdown + rich hyperlinks
    \\
    \\Usage:
    \\  clipmd [transform] [-f md|html|rtf] [-c CONFIG]   transform stdin -> stdout
    \\  clipmd daemon [-c CONFIG]                         run the menu-bar / socket daemon
    \\  clipmd clip [-c CONFIG]                           transform the clipboard (macOS)
    \\  clipmd run                                        ask the daemon to transform the clipboard
    \\  clipmd send [-f md|html|rtf]                      pipe stdin through the daemon
    \\  clipmd config path|init|show [-c CONFIG]          manage configuration
    \\  clipmd version | help
    \\
    \\Options:
    \\  -f, --format   output format: md (default), html, rtf
    \\  -c, --config   path to a config file (default: $CLIPMD_CONFIG or
    \\                 ~/.config/clipmd/config.zon)
    \\
    \\Rule file format (one rule per line):
    \\  <url-pattern>  =>  <display-template>
    \\  e.g.  *.ticketsystem.com/{id}  =>  {id}
    \\
;

const Options = struct {
    command: []const u8 = "transform",
    sub: ?[]const u8 = null,
    format: transform.Format = .md,
    config_path: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var opts = parseArgs(args[1..]) catch {
        try writeStderr(io, usage);
        return 2;
    };

    if (mem.eql(u8, opts.command, "help") or mem.eql(u8, opts.command, "--help") or mem.eql(u8, opts.command, "-h")) {
        try writeStdout(io, usage);
        return 0;
    }
    if (mem.eql(u8, opts.command, "version") or mem.eql(u8, opts.command, "--version")) {
        try writeStdout(io, "clipmd " ++ version ++ "\n");
        return 0;
    }

    const cfg_path = try resolveConfigPath(arena, init, opts.config_path);

    if (mem.eql(u8, opts.command, "config")) {
        return cmdConfig(gpa, io, &opts, cfg_path);
    }
    if (mem.eql(u8, opts.command, "run")) {
        return cmdRun(gpa, io, init);
    }
    if (mem.eql(u8, opts.command, "send")) {
        return cmdSend(gpa, io, init, opts.format);
    }

    // Remaining commands need the rule engine.
    var cfg = loadConfig(gpa, io, cfg_path) catch |err| {
        try printErr(io, "failed to load config '{s}': {t}\n", .{ cfg_path.path, err });
        return 1;
    };
    defer cfg.deinit();
    const engine = transform.Engine.init(&cfg);

    if (mem.eql(u8, opts.command, "transform")) {
        return cmdTransform(gpa, io, engine, opts.format);
    } else if (mem.eql(u8, opts.command, "clip")) {
        return cmdClip(gpa, io, engine);
    } else if (mem.eql(u8, opts.command, "daemon")) {
        return cmdDaemon(gpa, io, init, &engine);
    }

    try printErr(io, "unknown command: {s}\n", .{opts.command});
    try writeStderr(io, usage);
    return 2;
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

fn parseArgs(args: []const [:0]const u8) !Options {
    var opts: Options = .{};
    var have_command = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (mem.eql(u8, a, "-f") or mem.eql(u8, a, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.format = transform.Format.parse(args[i]) orelse return error.BadFormat;
        } else if (mem.eql(u8, a, "-c") or mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.config_path = args[i];
        } else if (!have_command) {
            opts.command = a;
            have_command = true;
        } else if (opts.sub == null) {
            opts.sub = a;
        } else {
            return error.TooManyArgs;
        }
    }
    return opts;
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn cmdTransform(gpa: Allocator, io: std.Io, engine: transform.Engine, fmt: transform.Format) !u8 {
    const input = try readAllStdin(gpa, io);
    defer gpa.free(input);

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try engine.transform(gpa, &fw.interface, input, fmt);
    try fw.interface.flush();
    return 0;
}

fn cmdClip(gpa: Allocator, io: std.Io, engine: transform.Engine) !u8 {
    if (comptime !is_macos) {
        try writeStderr(io, "clip: the OS clipboard is only supported on macOS\n");
        return 1;
    }
    const summary = clipboard.transformClipboard(gpa, engine) catch |err| {
        try printErr(io, "clip failed: {t}\n", .{err});
        return 1;
    };
    try printErr(io, "clipboard transformed: {d}/{d} URLs matched a rule\n", .{ summary.matched, summary.total });
    return 0;
}

const ClipCtx = struct { gpa: Allocator, engine: *const transform.Engine };

fn clipThunk(ptr: *anyopaque) anyerror!ipc.ClipSummary {
    const ctx: *ClipCtx = @ptrCast(@alignCast(ptr));
    return clipboard.transformClipboard(ctx.gpa, ctx.engine.*);
}

fn cmdDaemon(gpa: Allocator, io: std.Io, init: std.process.Init, engine: *const transform.Engine) !u8 {
    const sock_path = try resolveSockPath(init.arena.allocator(), init);

    var clip_ctx = ClipCtx{ .gpa = gpa, .engine = engine };
    const clip_fn: ?ipc.ClipFn = if (comptime is_macos) clipThunk else null;

    var server = ipc.Server.init(gpa, engine, sock_path, clip_fn, &clip_ctx) catch |err| {
        try printErr(io, "failed to start daemon socket at '{s}': {t}\n", .{ sock_path, err });
        return 1;
    };
    defer server.deinit();

    try printErr(io, "clipmd daemon listening on {s}\n", .{sock_path});

    if (comptime is_macos) {
        // Serve socket requests on a background thread; run the Cocoa event
        // loop (menu bar + hotkey) on the main thread. The hotkey is already
        // parsed and validated at config load.
        const thread = try std.Thread.spawn(.{}, ipc.Server.run, .{&server});
        thread.detach();
        try printErr(io, "menu-bar item active; global hotkey: {s}\n", .{engine.cfg.hotkey_spec});
        try app.run(gpa, engine, engine.cfg.hotkey);
    } else {
        try printErr(io, "(no menu bar on this platform; serving socket only)\n", .{});
        server.run();
    }
    return 0;
}

fn cmdRun(gpa: Allocator, io: std.Io, init: std.process.Init) !u8 {
    const sock_path = try resolveSockPath(init.arena.allocator(), init);
    const resp = ipc.request(gpa, sock_path, "CLIP\n") catch |err| {
        try printErr(io, "could not reach daemon at '{s}': {t}\n", .{ sock_path, err });
        try writeStderr(io, "is the daemon running?  start it with: clipmd daemon\n");
        return 1;
    };
    defer gpa.free(resp);
    try writeStdout(io, resp);
    return if (mem.startsWith(u8, resp, "OK")) 0 else 1;
}

fn cmdSend(gpa: Allocator, io: std.Io, init: std.process.Init, fmt: transform.Format) !u8 {
    const sock_path = try resolveSockPath(init.arena.allocator(), init);
    const input = try readAllStdin(gpa, io);
    defer gpa.free(input);

    const payload = try std.fmt.allocPrint(gpa, "TRANSFORM:{t}\n{s}", .{ fmt, input });
    defer gpa.free(payload);

    const resp = ipc.request(gpa, sock_path, payload) catch |err| {
        try printErr(io, "could not reach daemon at '{s}': {t}\n", .{ sock_path, err });
        return 1;
    };
    defer gpa.free(resp);
    try writeStdout(io, resp);
    return 0;
}

fn cmdConfig(gpa: Allocator, io: std.Io, opts: *const Options, cfg_path: ConfigPath) !u8 {
    const sub = opts.sub orelse "path";
    const path = cfg_path.path;

    if (mem.eql(u8, sub, "path")) {
        try printOut(io, "{s}\n", .{path});
        return 0;
    } else if (mem.eql(u8, sub, "init")) {
        if (mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            if (slash > 0) std.Io.Dir.cwd().createDirPath(io, path[0..slash]) catch |err| {
                try printErr(io, "could not create config directory: {t}\n", .{err});
                return 1;
            };
        }
        // Don't clobber an existing config.
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
            try printErr(io, "config already exists: {s}\n", .{path});
            return 1;
        } else |_| {}
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = config.example }) catch |err| {
            try printErr(io, "could not write config: {t}\n", .{err});
            return 1;
        };
        try printErr(io, "wrote example config to {s}\n", .{path});
        return 0;
    } else if (mem.eql(u8, sub, "show")) {
        var cfg = loadConfig(gpa, io, cfg_path) catch |err| {
            try printErr(io, "failed to load config '{s}': {t}\n", .{ path, err });
            return 1;
        };
        defer cfg.deinit();
        try printOut(io, "{d} rule(s) from {s}:\n", .{ cfg.rules.len, path });
        for (cfg.rules) |rule| {
            try printOut(io, "  {s} => {s}\n", .{ rule.pattern.source, rule.template });
        }
        try printOut(io, "hotkey: {s}\n", .{cfg.hotkey_spec});
        return 0;
    }
    try printErr(io, "config: unknown subcommand '{s}' (use path|init|show)\n", .{sub});
    return 2;
}

// ---------------------------------------------------------------------------
// Config / path resolution
// ---------------------------------------------------------------------------

const ConfigPath = struct {
    path: []const u8,
    /// True when the path came from `-c` or `$CLIPMD_CONFIG` (the user named it
    /// explicitly), false for the implicit default location.
    explicit: bool,
};

/// Load config. A malformed config is always a hard error. A *missing* file is
/// fatal only when the path was named explicitly; the implicit default location
/// is allowed to be absent (treated as an empty rule set) so the tool works
/// out of the box.
fn loadConfig(gpa: Allocator, io: std.Io, cp: ConfigPath) !config.Config {
    // Detailed ZON parse errors (line:column) are written to stderr.
    var ebuf: [2048]u8 = undefined;
    var efw = std.Io.File.stderr().writer(io, &ebuf);
    defer efw.interface.flush() catch {};
    return config.load(gpa, io, cp.path, &efw.interface) catch |err| switch (err) {
        error.FileNotFound => if (cp.explicit) return err else config.empty(gpa),
        else => return err,
    };
}

fn resolveConfigPath(arena: Allocator, init: std.process.Init, flag: ?[]const u8) !ConfigPath {
    if (flag) |f| return .{ .path = f, .explicit = true };
    if (init.environ_map.get("CLIPMD_CONFIG")) |p| {
        if (p.len > 0) return .{ .path = p, .explicit = true };
    }
    const home = init.environ_map.get("HOME") orelse ".";
    const path = try std.fmt.allocPrint(arena, "{s}/.config/clipmd/config.zon", .{home});
    return .{ .path = path, .explicit = false };
}

fn resolveSockPath(arena: Allocator, init: std.process.Init) ![]const u8 {
    if (init.environ_map.get("CLIPMD_SOCK")) |p| return p;
    const dir = init.environ_map.get("TMPDIR") orelse "/tmp";
    const trimmed = mem.trimEnd(u8, dir, "/");
    return std.fmt.allocPrint(arena, "{s}/clipmd.sock", .{trimmed});
}

// ---------------------------------------------------------------------------
// I/O helpers
// ---------------------------------------------------------------------------

fn readAllStdin(gpa: Allocator, io: std.Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &buf);
    return fr.interface.allocRemaining(gpa, .unlimited);
}

fn writeStdout(io: std.Io, text: []const u8) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(text);
    try fw.interface.flush();
}

fn writeStderr(io: std.Io, text: []const u8) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    try fw.interface.writeAll(text);
    try fw.interface.flush();
}

fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.print(fmt, args);
    try fw.interface.flush();
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    try fw.interface.print(fmt, args);
    try fw.interface.flush();
}
