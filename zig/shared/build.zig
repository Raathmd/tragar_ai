const std = @import("std");

// Standalone build for the shared protocol: exposes it as a reusable module and
// runs its test suite. The sender and receiver builds import protocol.zig as a
// module from this directory (see ../README.md). Targets Zig 0.16.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module dependents (sender/receiver) import as "protocol".
    _ = b.addModule("protocol", .{
        .root_source_file = b.path("protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 0.16: addTest takes a .root_module built via createModule.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run shared protocol tests");
    test_step.dependOn(&run_tests.step);
}
