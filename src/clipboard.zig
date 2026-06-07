//! Platform clipboard abstraction. The actual OS clipboard is only available on
//! macOS; on other platforms `transformClipboard` reports it as unsupported,
//! while the pipe/daemon transforms still work everywhere.

const std = @import("std");
const builtin = @import("builtin");
const transform = @import("transform.zig");
const ipc = @import("ipc.zig");

const is_macos = builtin.os.tag == .macos;
const pasteboard = if (is_macos) @import("macos/pasteboard.zig") else struct {};

pub const supported = is_macos;

/// Read the OS clipboard, transform it, and write all representations back.
/// Returns a count of matched/total URLs.
pub fn transformClipboard(gpa: std.mem.Allocator, engine: transform.Engine) !ipc.ClipSummary {
    if (comptime is_macos) {
        const text = try pasteboard.readText(gpa);
        defer gpa.free(text);

        const md = try render(gpa, engine, text, .md);
        defer gpa.free(md);
        const html = try render(gpa, engine, text, .html);
        defer gpa.free(html);
        const rtf = try render(gpa, engine, text, .rtf);
        defer gpa.free(rtf);

        pasteboard.writeRich(md, html, rtf);

        const counts = try engine.count(gpa, text);
        return .{ .matched = counts.matched, .total = counts.total };
    } else {
        return error.Unsupported;
    }
}

fn render(gpa: std.mem.Allocator, engine: transform.Engine, text: []const u8, fmt: transform.Format) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try engine.transform(gpa, &aw.writer, text, fmt);
    return aw.toOwnedSlice();
}
