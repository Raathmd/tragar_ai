const std = @import("std");

// Builds the Pastel schema-dump utility. Defaults to x86-windows (the Pastel
// ODBC driver is 32-bit), links libc + the odbc32 import lib. Override the
// target with `-Dtarget=...` if you ever need to.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu },
    });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.linkSystemLibrary("odbc32", .{});

    const exe = b.addExecutable(.{ .name = "schema-dump", .root_module = mod });
    b.installArtifact(exe);
}
