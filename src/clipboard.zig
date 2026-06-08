//! Platform clipboard abstraction. The actual OS clipboard is only available on
//! macOS; on other platforms `transformClipboard` reports it as unsupported,
//! while the pipe/daemon transforms still work everywhere.

const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ipc.zig");
const service = @import("service.zig");

const is_macos = builtin.os.tag == .macos;
const pasteboard = if (is_macos) @import("macos/pasteboard.zig") else struct {};

pub const supported = is_macos;

/// Read the OS clipboard, transform it through `svc`, and write all
/// representations back. Returns a count of matched/total URLs.
pub fn transformClipboard(io: std.Io, gpa: std.mem.Allocator, svc: *service.Service) !ipc.ClipSummary {
    if (comptime is_macos) {
        const text = try pasteboard.readText(gpa);
        defer gpa.free(text);

        const rendered = try svc.renderAll(io, gpa, text);
        defer gpa.free(rendered.md);
        defer gpa.free(rendered.html);
        defer gpa.free(rendered.rtf);

        pasteboard.writeRich(rendered.md, rendered.html, rendered.rtf);
        return .{ .matched = rendered.counts.matched, .total = rendered.counts.total };
    } else {
        return error.Unsupported;
    }
}
