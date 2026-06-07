//! A thread-safe holder for the active configuration that can be hot-reloaded.
//!
//! The daemon's socket thread, the macOS menu/hotkey (main thread), and the
//! file watcher all touch the engine concurrently, so config access is guarded
//! by a mutex. `reload` parses the file first and only swaps the live config in
//! on success — a broken edit never takes down a running daemon.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const transform = @import("transform.zig");
const keybind = @import("keybind.zig");

/// A tiny spinlock. Lock hold-times here are microseconds (an in-memory
/// transform, or a pointer swap) and reload is rare, so spinning is fine and
/// avoids threading an `Io` through `std.Io.Mutex` on every lock.
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

pub const Service = struct {
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    lock: SpinLock = .{},
    cfg: config.Config,

    pub fn init(gpa: Allocator, io: std.Io, path: []const u8, cfg: config.Config) Service {
        return .{ .gpa = gpa, .io = io, .path = path, .cfg = cfg };
    }

    pub fn deinit(self: *Service) void {
        self.cfg.deinit();
        self.* = undefined;
    }

    /// Re-read and re-parse the config file, swapping it in atomically. On any
    /// error the current config is kept and the error is returned.
    pub fn reload(self: *Service) !void {
        const fresh = try config.load(self.gpa, self.io, self.path, null);
        self.lock.acquire();
        defer self.lock.release();
        var old = self.cfg;
        self.cfg = fresh;
        old.deinit();
    }

    /// Transform `text` into `w` using the current rules.
    pub fn transformInto(self: *Service, gpa: Allocator, w: *std.Io.Writer, text: []const u8, fmt: transform.Format) !void {
        self.lock.acquire();
        defer self.lock.release();
        const engine = transform.Engine.init(&self.cfg);
        try engine.transform(gpa, w, text, fmt);
    }

    pub const Rendered = struct {
        md: []u8,
        html: []u8,
        rtf: []u8,
        counts: transform.Engine.Counts,
    };

    /// Render all three representations of `text` under a single lock, so they
    /// reflect one consistent snapshot of the rules. Caller frees md/html/rtf.
    pub fn renderAll(self: *Service, gpa: Allocator, text: []const u8) !Rendered {
        self.lock.acquire();
        defer self.lock.release();
        const engine = transform.Engine.init(&self.cfg);

        const md = try renderOne(gpa, engine, text, .md);
        errdefer gpa.free(md);
        const html = try renderOne(gpa, engine, text, .html);
        errdefer gpa.free(html);
        const rtf = try renderOne(gpa, engine, text, .rtf);
        errdefer gpa.free(rtf);

        return .{ .md = md, .html = html, .rtf = rtf, .counts = try engine.count(gpa, text) };
    }

    /// The current global hotkey.
    pub fn hotkey(self: *Service) keybind.Combo {
        self.lock.acquire();
        defer self.lock.release();
        return self.cfg.hotkey;
    }
};

fn renderOne(gpa: Allocator, engine: transform.Engine, text: []const u8, fmt: transform.Format) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try engine.transform(gpa, &aw.writer, text, fmt);
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "transform uses current rules" {
    const cfg = try config.parse(testing.allocator,
        \\.{ .rules = .{ .{ .match = "*.ticketsystem.com/{id}", .display = "{id}" } } }
    , null);
    var svc = Service.init(testing.allocator, undefined, "unused", cfg);
    defer svc.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try svc.transformInto(testing.allocator, &aw.writer, "https://x.ticketsystem.com/ABC-1", .md);
    try testing.expectEqualStrings("[ABC-1](https://x.ticketsystem.com/ABC-1)", aw.written());
}
