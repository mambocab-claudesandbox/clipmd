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
        // Compile the Swift AppKit layer and link its object. This needs the
        // Swift toolchain (Xcode / Command Line Tools), so it only runs for a
        // native macOS build — the same place the final link already happens.
        linkSwiftLayer(b, exe_mod);
    }

    const exe = b.addExecutable(.{ .name = "clipmd", .root_module = exe_mod });
    b.installArtifact(exe);

    // `zig build bundle` assembles zig-out/clipmd.app — a minimal bundle whose
    // only job is to register the macOS "replace selection" Service. It wraps
    // the same clipmd binary (which enters Services-provider mode when launched
    // from a bundle). macOS only; the menu-bar daemon stays unbundled.
    if (target.result.os.tag == .macos) {
        const bundle_bin = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "clipmd.app/Contents/MacOS" } },
        });
        const bundle_plist = b.addInstallFileWithDir(
            b.path("src/macos/Info.plist"),
            .{ .custom = "clipmd.app/Contents" },
            "Info.plist",
        );
        const bundle_step = b.step("bundle", "Assemble zig-out/clipmd.app (macOS Services provider)");
        bundle_step.dependOn(&bundle_bin.step);
        bundle_step.dependOn(&bundle_plist.step);
    }

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

    // Compile-check the macOS GUI sources without linking (no SDK or Swift
    // toolchain needed). This validates the Zig half of the macOS layer,
    // including the `extern fn` declarations of the Swift C-ABI surface; the
    // Swift implementation itself is only built by `swiftc` in a native
    // macOS `zig build`. Produces an object file via `zig build check-macos`.
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

/// Compile `src/macos/clipmd_macos.swift` to an object with `swiftc` and link
/// it into `mod`. The Swift object carries Mach-O autolink hints for the Swift
/// runtime that the linker honours; we add the active SDK's Swift library path
/// (discovered via `xcrun`) so those hints resolve at link time. The runtime
/// dylibs themselves ship with macOS (10.14.4+), so the final binary stays
/// self-contained. `swiftc` defaults to the host architecture, matching a
/// native `zig build`.
fn linkSwiftLayer(b: *std.Build, mod: *std.Build.Module) void {
    const swiftc = b.addSystemCommand(&.{
        "swiftc",
        "-O",
        "-parse-as-library",
        "-module-name",
        "ClipmdMacOS",
        "-emit-object",
        "-o",
    });
    const swift_obj = swiftc.addOutputFileArg("clipmd_macos.o");
    swiftc.addFileArg(b.path("src/macos/clipmd_macos.swift"));
    mod.addObjectFile(swift_obj);

    // Link-time stubs for the Swift runtime live under the SDK.
    const sdk_path = std.mem.trimRight(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), "\n");
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr", "lib", "swift" }) });
}
