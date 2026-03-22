const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library
    const lib = b.addStaticLibrary(.{
        .name = "cclaude",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.addIncludePath(b.path("src"));
    b.installArtifact(lib);

    // Shared library for Android
    const shared_lib = b.addSharedLibrary(.{
        .name = "cclaude",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_lib.addIncludePath(b.path("src"));
    b.installArtifact(shared_lib);

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
