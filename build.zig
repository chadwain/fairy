const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "llvm", "Use LLVM") orelse false;

    const fairy = b.addModule("fairy", .{
        .root_source_file = b.path("source/fairy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_exe = b.addExecutable(.{
        .name = "test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fairy", .module = fairy },
            },
        }),
        .use_llvm = use_llvm,
    });
    b.installArtifact(test_exe);
}
