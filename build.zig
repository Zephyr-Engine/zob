const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zob", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Example executable
    const example = b.addExecutable(.{
        .name = "zob-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zob", .module = mod },
            },
        }),
    });

    const example_step = b.step("example", "Run the example");
    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    example_step.dependOn(&run_example.step);
}
