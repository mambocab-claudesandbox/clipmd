//! A thread-safe holder for the active configuration that can be hot-reloaded.
//!
//! The daemon's socket thread, the macOS menu/hotkey (main thread), and the
//! file watcher all touch the engine concurrently, so config access is guarded
//! by a `std.Io.Mutex`. The `Io` is threaded in per call rather than stored, so
//! synchronization is explicit at every call site. `reload` parses the file
//! first and only swaps the live config in on success — a broken edit never
//! takes down a running daemon.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const transform = @import("transform.zig");
const keybind = @import("keybind.zig");

pub const Service = struct {
    gpa: Allocator,
    path: []const u8,
    mutex: Io.Mutex = .init,
    cfg: config.Config,

    pub fn init(gpa: Allocator, path: []const u8, cfg: config.Config) Service {
        return .{ .gpa = gpa, .path = path, .cfg = cfg };
    }

    pub fn deinit(self: *Service) void {
        self.cfg.deinit();
        self.* = undefined;
    }

    /// Re-read and re-parse the config file, swapping it in atomically. On any
    /// error the current config is kept and the error is returned.
    pub fn reload(self: *Service, io: Io) !void {
        const fresh = try config.load(self.gpa, io, self.path, null);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var old = self.cfg;
        self.cfg = fresh;
        old.deinit();
    }

    /// Transform `text` into `w` using the current rules.
    pub fn transformInto(self: *Service, io: Io, gpa: Allocator, w: *Io.Writer, text: []const u8, fmt: transform.Format) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
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
    pub fn renderAll(self: *Service, io: Io, gpa: Allocator, text: []const u8) !Rendered {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
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
    pub fn hotkey(self: *Service, io: Io) keybind.Combo {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.cfg.hotkey;
    }

    /// Copy the current hotkey spec string into `buf` (the spec aliases the
    /// config arena, so it must be copied while the lock is held).
    pub fn hotkeySpec(self: *Service, io: Io, buf: []u8) []const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const spec = self.cfg.hotkey_spec;
        const n = @min(spec.len, buf.len);
        @memcpy(buf[0..n], spec[0..n]);
        return buf[0..n];
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = try config.parse(testing.allocator,
        \\.{ .rules = .{ .{ .match = "*.ticketsystem.com/{id}", .display = "{id}" } } }
    , null);
    var svc = Service.init(testing.allocator, "unused", cfg);
    defer svc.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try svc.transformInto(io, testing.allocator, &aw.writer, "https://x.ticketsystem.com/ABC-1", .md);
    try testing.expectEqualStrings("[ABC-1](https://x.ticketsystem.com/ABC-1)", aw.written());
}
