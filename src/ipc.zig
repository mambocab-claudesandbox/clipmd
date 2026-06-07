//! Unix-domain-socket IPC between the `clipmd` CLI and a running daemon.
//!
//! Wire protocol (one request per connection): the client writes a request,
//! then half-closes its write side; the server reads to EOF, acts, writes a
//! response, and closes. A request is a command line, optionally followed by a
//! body:
//!
//!   PING\n                      -> PONG\n
//!   CLIP\n                      -> OK matched=<n> total=<m>\n   (or ERR ...)
//!   TRANSFORM:<fmt>\n<body...>  -> <transformed body>
//!
//! Sockets are used via libc directly because the Zig 0.16 standard library's
//! socket helpers moved to the Io-based networking API; libc is portable across
//! macOS and Linux and keeps this layer simple and synchronous.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const posix = std.posix;
const c = std.c;
const transform = @import("transform.zig");

const SHUT_WR = 1;

pub const ClipSummary = struct { matched: usize, total: usize };

/// Callback invoked for a CLIP request: read the OS clipboard, transform it,
/// write it back. Implemented by the platform clipboard layer.
pub const ClipFn = *const fn (ctx: *anyopaque) anyerror!ClipSummary;

pub const Server = struct {
    gpa: Allocator,
    engine: *const transform.Engine,
    clip_fn: ?ClipFn,
    clip_ctx: *anyopaque,
    path: []const u8,
    fd: posix.fd_t,

    /// Create, bind and listen on the socket at `path`. A stale socket file is
    /// removed first.
    pub fn init(
        gpa: Allocator,
        engine: *const transform.Engine,
        path: []const u8,
        clip_fn: ?ClipFn,
        clip_ctx: *anyopaque,
    ) !Server {
        const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);

        var addr: posix.sockaddr.un = undefined;
        const len = try fillAddr(&addr, path);

        // Remove any stale socket from a previous run.
        _ = c.unlink(try toCPath(path));

        if (c.bind(fd, @ptrCast(&addr), len) != 0) return error.BindFailed;
        if (c.listen(fd, 16) != 0) return error.ListenFailed;

        return .{
            .gpa = gpa,
            .engine = engine,
            .clip_fn = clip_fn,
            .clip_ctx = clip_ctx,
            .path = path,
            .fd = fd,
        };
    }

    pub fn deinit(self: *Server) void {
        _ = c.close(self.fd);
        _ = c.unlink(toCPath(self.path) catch return);
    }

    /// Accept and serve connections until an unrecoverable accept error.
    pub fn run(self: *Server) void {
        while (true) {
            const conn = c.accept(self.fd, null, null);
            if (conn < 0) {
                if (std.posix.errno(@as(isize, conn)) == .INTR) continue;
                return;
            }
            self.handle(conn) catch {};
            _ = c.close(conn);
        }
    }

    fn handle(self: *Server, conn: posix.fd_t) !void {
        const req = try readAll(self.gpa, conn);
        defer self.gpa.free(req);

        const nl = mem.indexOfScalar(u8, req, '\n') orelse req.len;
        const cmd = mem.trim(u8, req[0..nl], " \t\r");
        const body = if (nl < req.len) req[nl + 1 ..] else "";

        if (mem.eql(u8, cmd, "PING")) {
            try writeAll(conn, "PONG\n");
        } else if (mem.eql(u8, cmd, "CLIP")) {
            try self.handleClip(conn);
        } else if (mem.startsWith(u8, cmd, "TRANSFORM:")) {
            try self.handleTransform(conn, cmd["TRANSFORM:".len..], body);
        } else {
            try writeAll(conn, "ERR unknown command\n");
        }
    }

    fn handleClip(self: *Server, conn: posix.fd_t) !void {
        const clip = self.clip_fn orelse {
            try writeAll(conn, "ERR clipboard not supported on this platform\n");
            return;
        };
        const summary = clip(self.clip_ctx) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "ERR {t}\n", .{err}) catch "ERR clipboard failure\n";
            try writeAll(conn, msg);
            return;
        };
        var buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "OK matched={d} total={d}\n", .{ summary.matched, summary.total });
        try writeAll(conn, msg);
    }

    fn handleTransform(self: *Server, conn: posix.fd_t, fmt_str: []const u8, body: []const u8) !void {
        const fmt = transform.Format.parse(fmt_str) orelse {
            try writeAll(conn, "ERR bad format\n");
            return;
        };
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        try self.engine.transform(self.gpa, &aw.writer, body, fmt);
        try writeAll(conn, aw.written());
    }
};

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Send a raw request to the daemon at `path` and return its full response.
/// Caller owns the returned memory.
pub fn request(gpa: Allocator, path: []const u8, payload: []const u8) ![]u8 {
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);

    var addr: posix.sockaddr.un = undefined;
    const len = try fillAddr(&addr, path);
    if (c.connect(fd, @ptrCast(&addr), len) != 0) return error.ConnectFailed;

    try writeAll(fd, payload);
    _ = c.shutdown(fd, SHUT_WR);
    return readAll(gpa, fd);
}

/// Return true if a daemon is reachable at `path`.
pub fn ping(gpa: Allocator, path: []const u8) bool {
    const resp = request(gpa, path, "PING\n") catch return false;
    defer gpa.free(resp);
    return mem.startsWith(u8, resp, "PONG");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fillAddr(addr: *posix.sockaddr.un, path: []const u8) !posix.socklen_t {
    if (path.len >= addr.path.len) return error.PathTooLong;
    addr.* = .{ .family = posix.AF.UNIX, .path = undefined };
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    return @intCast(@sizeOf(posix.sockaddr.un));
}

threadlocal var path_buf: [256]u8 = undefined;

fn toCPath(path: []const u8) ![*:0]const u8 {
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    return path_buf[0..path.len :0];
}

fn readAll(gpa: Allocator, fd: posix.fd_t) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            if (std.posix.errno(@as(isize, n)) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        try list.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    return list.toOwnedSlice(gpa);
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (std.posix.errno(@as(isize, n)) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const config = @import("config.zig");
const testing = std.testing;

test "server round-trip: ping and transform" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var cfg = try config.parse(testing.allocator,
        \\.{ .rules = .{ .{ .match = "*.ticketsystem.com/{id}", .display = "{id}" } } }
    , null);
    defer cfg.deinit();
    const engine = transform.Engine.init(&cfg);

    var dummy: u8 = 0;
    const sock_path = "/tmp/clipmd-test.sock";
    var server = try Server.init(testing.allocator, &engine, sock_path, null, &dummy);
    defer server.deinit();

    const T = struct {
        fn run(s: *Server) void {
            // Serve exactly two connections then stop, so the test terminates.
            for (0..2) |_| {
                const conn = c.accept(s.fd, null, null);
                if (conn < 0) return;
                s.handle(conn) catch {};
                _ = c.close(conn);
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, T.run, .{&server});
    defer thread.join();

    try testing.expect(ping(testing.allocator, sock_path));

    const resp = try request(
        testing.allocator,
        sock_path,
        "TRANSFORM:md\nhttps://x.ticketsystem.com/ABC-1",
    );
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("[ABC-1](https://x.ticketsystem.com/ABC-1)", resp);
}
