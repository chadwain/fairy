const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "llvm", "Use LLVM") orelse false;
    const build_server = b.option(bool, "server", "Build the server") orelse false;
    const build_client = b.option(bool, "client", "Build the client") orelse false;
    const build_unit_tests = b.option(bool, "unit-test", "Build the unit tests") orelse false;

    const fairy = b.addModule("fairy", .{
        .root_source_file = b.path("source/fairy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .name = "unit-test",
        .root_module = fairy,
        .use_llvm = use_llvm,
    });
    if (build_unit_tests) {
        b.installArtifact(unit_tests);
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_tests_step = b.step("unit-test", "Run unit tests");
    unit_tests_step.dependOn(&run_unit_tests.step);

    const HostType = enum { server, client };

    inline for (std.enums.values(HostType)) |e| {
        const choice = switch (e) {
            .server => build_server,
            .client => build_client,
        };
        if (choice) {
            const build_options = b.addOptions();
            build_options.addOption(HostType, "host_type", e);

            const test_app = b.addExecutable(.{
                .name = @tagName(e),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "fairy", .module = fairy },
                        .{ .name = "build-options", .module = build_options.createModule() },
                    },
                }),
                .use_llvm = use_llvm,
            });
            b.installArtifact(test_app);
        }
    }
}
