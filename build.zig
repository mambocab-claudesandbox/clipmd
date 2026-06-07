const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // libc provides the socket calls used by the daemon (and is required to
    // link the macOS frameworks below).
    exe_mod.link_libc = true;

    if (target.result.os.tag == .macos) {
        exe_mod.linkFramework("AppKit", .{});
        exe_mod.linkFramework("Carbon", .{});
        exe_mod.linkFramework("Foundation", .{});
    }

    const exe = b.addExecutable(.{ .name = "clipmd", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run clipmd");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.link_libc = true;
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Compile-check the macOS GUI sources without linking (no SDK needed).
    // Produces an object file via `zig build check-macos`.
    const macos_check_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos }),
        .optimize = .Debug,
    });
    macos_check_mod.link_libc = true;
    const macos_obj = b.addObject(.{ .name = "clipmd-macos-check", .root_module = macos_check_mod });
    const check_step = b.step("check-macos", "Compile-check the macOS sources (no link)");
    check_step.dependOn(&macos_obj.step);
}
