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

    // Benchmark executable (always ReleaseFast for accurate measurements)
    const benchmark = b.addExecutable(.{
        .name = "zob-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zob", .module = mod },
            },
        }),
    });

    const bench_step = b.step("bench", "Run performance benchmarks");
    const run_bench = b.addRunArtifact(benchmark);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    bench_step.dependOn(&run_bench.step);
}
