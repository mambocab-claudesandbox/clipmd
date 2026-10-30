//! Aggregates unit tests from the portable modules so `zig build test` runs
//! them all. The macOS-only modules (`macos/*.zig`, plus the Swift AppKit
//! layer they call) are compile-checked separately — they require the macOS
//! SDK to link and the Swift toolchain to build — via `zig build check-macos`.

test {
    _ = @import("pattern.zig");
    _ = @import("rtf.zig");
    _ = @import("config.zig");
    _ = @import("transform.zig");
    _ = @import("ipc.zig");
    _ = @import("keybind.zig");
    _ = @import("service.zig");
}
