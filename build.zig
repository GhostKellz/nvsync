const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Library linkage (dynamic or static)",
    ) orelse .dynamic;

    // Zig module for Zig consumers
    const nvsync_mod = b.addModule("nvsync", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C API shared/static library
    const lib = b.addLibrary(.{
        .linkage = linkage,
        .name = "nvsync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Install the library
    b.installArtifact(lib);

    // Install C header
    b.installFile("include/nvsync.h", "include/nvsync.h");

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "nvsync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nvsync", .module = nvsync_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests for module
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Tests for C API
    const c_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_c_api_tests = b.addRunArtifact(c_api_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_c_api_tests.step);

    // Check step
    const check_step = b.step("check", "Check if code compiles");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&exe.step);
}
