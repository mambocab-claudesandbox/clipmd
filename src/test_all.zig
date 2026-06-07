//! Aggregates unit tests from the portable modules so `zig build test` runs
//! them all. The macOS-only modules are compile-checked separately (they
//! require the macOS SDK to link).

test {
    _ = @import("pattern.zig");
    _ = @import("rtf.zig");
    _ = @import("config.zig");
    _ = @import("transform.zig");
    _ = @import("ipc.zig");
    _ = @import("keybind.zig");
}
