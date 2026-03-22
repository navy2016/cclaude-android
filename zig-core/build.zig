const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared_lib = b.addSharedLibrary(.{
        .name = "cclaude",
        .root_source_file = b.path("src/runtime/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(shared_lib);

    _ = b.step("test", "No-op");
}
