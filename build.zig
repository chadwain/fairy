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

    const unit_tests = b.addTest(.{
        .name = "fairy-unit-tests",
        .root_module = fairy,
        .use_llvm = use_llvm,
    });
    b.installArtifact(unit_tests);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_tests_step = b.step("unit-tests", "Run unit tests");
    unit_tests_step.dependOn(&run_unit_tests.step);

    const test_app = b.addExecutable(.{
        .name = "test-app",
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
    b.installArtifact(test_app);

    const run_test_app = b.addRunArtifact(test_app);
    run_test_app.addPassthruArgs();
    const test_app_step = b.step("test-app", "Run a test app");
    test_app_step.dependOn(&run_test_app.step);
}
