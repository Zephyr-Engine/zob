const std = @import("std");
const zob = @import("zob");
const Io = std.Io;

const NoOpJob = struct {
    pub fn execute(self: @This()) void {
        _ = self;
    }
};

const TrivialJob = struct {
    a: i64,
    b: i64,

    pub fn execute(self: @This()) i64 {
        return self.a + self.b;
    }
};

/// Configurable-weight compute job.
/// Work scales linearly with `iters`.
const ComputeJob = struct {
    seed: u64,
    iters: u32,

    pub fn execute(self: @This()) u64 {
        var x = self.seed;
        for (0..self.iters) |_| {
            x = x *% 6364136223846793005 +% 1442695040888963407;
        }
        return x;
    }
};

const Config = struct {
    warmup: usize = 5,
    iterations: usize = 20,
    scale: usize = 1, // multiplier for batch sizes
    work: u32 = 100, // loop iterations per job (controls job weight)

    fn batchSize(self: Config, base: usize) usize {
        return base * self.scale;
    }

    fn parse(init: std.process.Init) Config {
        var cfg: Config = .{};
        var it = std.process.Args.Iterator.init(init.minimal.args);
        _ = it.skip(); // skip argv[0]
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printUsage();
                std.process.exit(0);
            } else if (parseNamedArg(arg, "--scale=")) |v| {
                cfg.scale = v;
            } else if (parseNamedArg(arg, "--iters=")) |v| {
                cfg.iterations = v;
            } else if (parseNamedArg(arg, "--warmup=")) |v| {
                cfg.warmup = v;
            } else if (parseNamedArg(arg, "--work=")) |v| {
                cfg.work = @intCast(v);
            } else {
                std.debug.print("unknown argument: {s}\n", .{arg});
                printUsage();
                std.process.exit(1);
            }
        }
        return cfg;
    }

    fn parseNamedArg(arg: []const u8, prefix: []const u8) ?usize {
        if (std.mem.startsWith(u8, arg, prefix)) {
            return std.fmt.parseInt(usize, arg[prefix.len..], 10) catch null;
        }
        return null;
    }

    fn printUsage() void {
        std.debug.print(
            \\
            \\  zob benchmark suite
            \\
            \\  Usage: zig build bench -- [options]
            \\
            \\  Options:
            \\    --scale=N    Batch size multiplier (default: 1)
            \\                   1  = default sizes (16-512 jobs)
            \\                   4  = moderate stress (64-2048 jobs)
            \\                   16 = heavy stress (256-8192 jobs)
            \\                   64 = extreme (1024-32768 jobs)
            \\    --iters=N    Measured iterations per benchmark (default: 20)
            \\    --warmup=N   Warmup iterations (default: 5)
            \\    --work=N     Loop iterations per job, controls job weight (default: 100)
            \\                   10    = ~trivial
            \\                   100   = ~1us
            \\                   1000  = ~10us
            \\                   10000 = ~100us
            \\    --help       Show this message
            \\
            \\  Examples:
            \\    zig build bench                           # default
            \\    zig build bench -- --scale=4              # 4x batch sizes
            \\    zig build bench -- --scale=16 --work=1000 # stress test with heavier jobs
            \\    zig build bench -- --scale=64 --iters=50  # extreme, more samples
            \\
        , .{});
    }
};

const BenchResult = struct {
    name: []const u8,
    min_ns: i96,
    max_ns: i96,
    median_ns: i96,
    mean_ns: i96,
    p99_ns: i96,
    iterations: usize,
    ops_count: usize,
};

fn timestamp(io: Io) i96 {
    return Io.Timestamp.now(io, .boot).nanoseconds;
}

fn benchSingleNoOp(scheduler: *zob.Scheduler, io: Io, _: Config) void {
    var f = scheduler.submit(NoOpJob, .{}, .normal);
    _ = f.await(io);
}

fn benchSingleTrivial(scheduler: *zob.Scheduler, io: Io, _: Config) void {
    var f = scheduler.submit(TrivialJob, .{ .a = 42, .b = 58 }, .normal);
    _ = f.await(io);
}

fn benchDynamicBatch(scheduler: *zob.Scheduler, io: Io, cfg: Config, count: usize) void {
    // Use heap-allocated batch for dynamic sizes
    const items = scheduler.allocator.alloc(ComputeJob, count) catch return;
    defer scheduler.allocator.free(items);

    for (items, 0..) |*item, i| {
        item.* = .{ .seed = @intCast(i + 1), .iters = cfg.work };
    }

    var batch = scheduler.submitBatch(ComputeJob, items, .normal) catch return;
    defer batch.deinit();
    const results = batch.awaitAll(io) catch return;
    scheduler.allocator.free(results);
}

fn benchBatch16(scheduler: *zob.Scheduler, io: Io, cfg: Config) void {
    benchDynamicBatch(scheduler, io, cfg, cfg.batchSize(16));
}

fn benchBatch64(scheduler: *zob.Scheduler, io: Io, cfg: Config) void {
    benchDynamicBatch(scheduler, io, cfg, cfg.batchSize(64));
}

fn benchBatch256(scheduler: *zob.Scheduler, io: Io, cfg: Config) void {
    benchDynamicBatch(scheduler, io, cfg, cfg.batchSize(256));
}

fn benchBatch512(scheduler: *zob.Scheduler, io: Io, cfg: Config) void {
    benchDynamicBatch(scheduler, io, cfg, cfg.batchSize(512));
}

fn benchChained(scheduler: *zob.Scheduler, io: Io, cfg: Config) void {
    const depth = @max(4, cfg.scale * 4);
    var val: i64 = 1;
    for (0..depth) |_| {
        var f = scheduler.submit(TrivialJob, .{ .a = val, .b = 1 }, .high);
        val = f.await(io);
    }
}

fn benchFanOutFanIn(scheduler: *zob.Scheduler, io: Io, cfg: Config) void {
    const count = cfg.batchSize(64);
    const items = scheduler.allocator.alloc(ComputeJob, count) catch return;
    defer scheduler.allocator.free(items);

    for (items, 0..) |*item, i| {
        item.* = .{ .seed = @intCast(i + 1), .iters = cfg.work };
    }

    var batch = scheduler.submitBatch(ComputeJob, items, .normal) catch return;
    defer batch.deinit();
    const results = batch.awaitAll(io) catch return;
    defer scheduler.allocator.free(results);

    // Reduce
    var total: u64 = 0;
    for (results) |r| total +%= r;

    var f = scheduler.submit(ComputeJob, .{ .seed = total, .iters = cfg.work }, .high);
    _ = f.await(io);
}

fn benchGameFrame(scheduler: *zob.Scheduler, io: Io, cfg: Config) void {
    // Physics (high), AI (normal), Audio (low)
    const phys_n = cfg.batchSize(16);
    const ai_n = cfg.batchSize(8);
    const audio_n = cfg.batchSize(4);

    const phys = scheduler.allocator.alloc(ComputeJob, phys_n) catch return;
    defer scheduler.allocator.free(phys);
    const ai = scheduler.allocator.alloc(ComputeJob, ai_n) catch return;
    defer scheduler.allocator.free(ai);
    const audio = scheduler.allocator.alloc(ComputeJob, audio_n) catch return;
    defer scheduler.allocator.free(audio);

    for (phys, 0..) |*item, i| item.* = .{ .seed = @intCast(i + 100), .iters = cfg.work };
    for (ai, 0..) |*item, i| item.* = .{ .seed = @intCast(i + 200), .iters = cfg.work };
    for (audio, 0..) |*item, i| item.* = .{ .seed = @intCast(i + 300), .iters = cfg.work };

    var pb = scheduler.submitBatch(ComputeJob, phys, .high) catch return;
    defer pb.deinit();
    var ab = scheduler.submitBatch(ComputeJob, ai, .normal) catch return;
    defer ab.deinit();
    var aub = scheduler.submitBatch(ComputeJob, audio, .low) catch return;
    defer aub.deinit();

    const pr = pb.awaitAll(io) catch return;
    scheduler.allocator.free(pr);
    const ar = ab.awaitAll(io) catch return;
    scheduler.allocator.free(ar);
    const aur = aub.awaitAll(io) catch return;
    scheduler.allocator.free(aur);
}

fn benchSustainedThroughput(scheduler: *zob.Scheduler, io: Io, cfg: Config) void {
    // Simulate sustained load: 10 waves of batches
    const wave_size = cfg.batchSize(64);
    for (0..10) |wave| {
        const items = scheduler.allocator.alloc(ComputeJob, wave_size) catch return;
        defer scheduler.allocator.free(items);

        for (items, 0..) |*item, i| {
            item.* = .{ .seed = @intCast(wave * wave_size + i + 1), .iters = cfg.work };
        }

        var batch = scheduler.submitBatch(ComputeJob, items, .normal) catch return;
        defer batch.deinit();
        const results = batch.awaitAll(io) catch return;
        scheduler.allocator.free(results);
    }
}

const BenchFn = *const fn (*zob.Scheduler, Io, Config) void;

fn runBench(
    io: Io,
    name: []const u8,
    ops_count: usize,
    benchFn: BenchFn,
    scheduler: *zob.Scheduler,
    cfg: Config,
    sample_buf: []i96,
) BenchResult {
    const n = @min(cfg.iterations, sample_buf.len);

    // Warmup
    for (0..cfg.warmup) |_| benchFn(scheduler, io, cfg);

    // Measure
    for (sample_buf[0..n]) |*s| {
        const start = timestamp(io);
        benchFn(scheduler, io, cfg);
        const end = timestamp(io);
        s.* = end - start;
    }

    std.mem.sort(i96, sample_buf[0..n], {}, std.sort.asc(i96));

    var sum: i96 = 0;
    for (sample_buf[0..n]) |s| sum += s;

    const p99_idx = @min(n - 1, (n * 99) / 100);

    return .{
        .name = name,
        .min_ns = sample_buf[0],
        .max_ns = sample_buf[n - 1],
        .median_ns = sample_buf[n / 2],
        .mean_ns = @divTrunc(sum, @as(i96, @intCast(n))),
        .p99_ns = sample_buf[p99_idx],
        .iterations = n,
        .ops_count = ops_count,
    };
}

fn formatNs(ns: i96) struct { value: f64, unit: []const u8 } {
    const abs: f64 = @floatFromInt(if (ns < 0) -ns else ns);
    if (abs < 1_000) return .{ .value = abs, .unit = "ns" };
    if (abs < 1_000_000) return .{ .value = abs / 1_000.0, .unit = "us" };
    if (abs < 1_000_000_000) return .{ .value = abs / 1_000_000.0, .unit = "ms" };
    return .{ .value = abs / 1_000_000_000.0, .unit = "s " };
}

fn printResult(r: BenchResult) void {
    const med = formatNs(r.median_ns);
    const mn = formatNs(r.min_ns);
    const p99 = formatNs(r.p99_ns);
    const per_op_ns = @divTrunc(r.median_ns, @as(i96, @intCast(r.ops_count)));
    const per_op = formatNs(per_op_ns);

    std.debug.print("  {s:<45} median: {d:>8.2} {s}  min: {d:>8.2} {s}  p99: {d:>8.2} {s}  per-op: {d:>8.2} {s}  ({d} ops)\n", .{
        r.name,
        med.value,
        med.unit,
        mn.value,
        mn.unit,
        p99.value,
        p99.unit,
        per_op.value,
        per_op.unit,
        r.ops_count,
    });
}

fn printSeparator() void {
    std.debug.print("  {s}\n", .{"-" ** 140});
}

fn printSummary(all: []const BenchResult, cfg: Config) void {
    std.debug.print("\n", .{});
    std.debug.print("  {s}\n", .{"=" ** 140});
    std.debug.print("  SUMMARY (scale={d}, work={d}, iters={d})\n", .{ cfg.scale, cfg.work, cfg.iterations });
    std.debug.print("  {s}\n", .{"=" ** 140});

    var single_overhead_ns: i96 = 0;
    var game_frame_ns: i96 = 0;
    var game_frame_ops: usize = 0;
    var throughput_ns: i96 = 0;
    var throughput_ops: usize = 0;
    var batch_512_ns: i96 = 0;
    var batch_512_ops: usize = 0;

    for (all) |r| {
        if (std.mem.eql(u8, r.name, "single/noop")) single_overhead_ns = r.median_ns;
        if (std.mem.startsWith(u8, r.name, "pattern/game-frame")) {
            game_frame_ns = r.median_ns;
            game_frame_ops = r.ops_count;
        }
        if (std.mem.startsWith(u8, r.name, "throughput/sustained")) {
            throughput_ns = r.median_ns;
            throughput_ops = r.ops_count;
        }
        if (std.mem.startsWith(u8, r.name, "batch-512")) {
            batch_512_ns = r.median_ns;
            batch_512_ops = r.ops_count;
        }
    }

    const overhead = formatNs(single_overhead_ns);
    std.debug.print("\n  Scheduling overhead (single noop):     {d:.2} {s}\n", .{ overhead.value, overhead.unit });

    if (game_frame_ns > 0) {
        const frame_budget_ns: i96 = 16_666_667;
        const pct: f64 = @as(f64, @floatFromInt(game_frame_ns)) / @as(f64, @floatFromInt(frame_budget_ns)) * 100.0;
        const gf = formatNs(game_frame_ns);
        std.debug.print("  Game frame ({d} jobs):          {d:>8.2} {s}  ({d:.2}% of 16.67ms @ 60fps)\n", .{ game_frame_ops, gf.value, gf.unit, pct });

        const frame_budget_120_ns: i96 = 8_333_333;
        const pct120: f64 = @as(f64, @floatFromInt(game_frame_ns)) / @as(f64, @floatFromInt(frame_budget_120_ns)) * 100.0;
        std.debug.print("  {s:<45}         ({d:.2}% of  8.33ms @ 120fps)\n", .{ "", pct120 });
    }

    if (batch_512_ns > 0) {
        const jobs_per_sec: f64 = @as(f64, @floatFromInt(batch_512_ops)) / (@as(f64, @floatFromInt(batch_512_ns)) / 1_000_000_000.0);
        const b = formatNs(batch_512_ns);
        std.debug.print("  Batch ({d} jobs):              {d:>8.2} {s}  ({d:.0} jobs/sec)\n", .{ batch_512_ops, b.value, b.unit, jobs_per_sec });
    }

    if (throughput_ns > 0) {
        const jobs_per_sec: f64 = @as(f64, @floatFromInt(throughput_ops)) / (@as(f64, @floatFromInt(throughput_ns)) / 1_000_000_000.0);
        const tp = formatNs(throughput_ns);
        std.debug.print("  Sustained (10 waves, {d} total):  {d:>8.2} {s}  ({d:.0} jobs/sec)\n", .{ throughput_ops, tp.value, tp.unit, jobs_per_sec });
    }

    std.debug.print("\n  {s}\n", .{"=" ** 140});
}

// ============================================================
// Main
// ============================================================

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const cfg = Config.parse(init);

    var scheduler = zob.Scheduler.init(io, allocator);

    // Allocate sample buffer once
    const max_samples = @max(cfg.iterations, 1000);
    const sample_buf = try allocator.alloc(i96, max_samples);
    defer allocator.free(sample_buf);

    std.debug.print("\n", .{});
    std.debug.print("  zob benchmark suite\n", .{});
    std.debug.print("  scale={d}  work={d}  warmup={d}  iters={d}\n", .{ cfg.scale, cfg.work, cfg.warmup, cfg.iterations });
    std.debug.print("\n", .{});

    var all_results: [20]BenchResult = undefined;
    var idx: usize = 0;

    // --- Single job overhead ---
    std.debug.print("  [single job overhead]\n", .{});
    printSeparator();

    all_results[idx] = runBench(io, "single/noop", 1, benchSingleNoOp, &scheduler, cfg, sample_buf);
    printResult(all_results[idx]);
    idx += 1;

    all_results[idx] = runBench(io, "single/trivial", 1, benchSingleTrivial, &scheduler, cfg, sample_buf);
    printResult(all_results[idx]);
    idx += 1;

    std.debug.print("\n", .{});

    // --- Batch scaling ---
    const b16 = cfg.batchSize(16);
    const b64 = cfg.batchSize(64);
    const b256 = cfg.batchSize(256);
    const b512 = cfg.batchSize(512);

    std.debug.print("  [batch scaling — work={d} per job]\n", .{cfg.work});
    printSeparator();

    var name_buf: [4][64]u8 = undefined;
    const names = [4]struct { size: usize, fn_ptr: BenchFn }{
        .{ .size = b16, .fn_ptr = benchBatch16 },
        .{ .size = b64, .fn_ptr = benchBatch64 },
        .{ .size = b256, .fn_ptr = benchBatch256 },
        .{ .size = b512, .fn_ptr = benchBatch512 },
    };

    for (names, 0..) |n, i| {
        const label = std.fmt.bufPrint(&name_buf[i], "batch-{d}", .{n.size}) catch "batch-?";
        all_results[idx] = runBench(io, label, n.size, n.fn_ptr, &scheduler, cfg, sample_buf);
        printResult(all_results[idx]);
        idx += 1;
    }

    std.debug.print("\n", .{});

    // --- Dependency patterns ---
    const chain_depth = @max(4, cfg.scale * 4);
    std.debug.print("  [dependency patterns]\n", .{});
    printSeparator();

    var chain_name_buf: [64]u8 = undefined;
    const chain_label = std.fmt.bufPrint(&chain_name_buf, "chain/{d}-deep sequential", .{chain_depth}) catch "chain/?";
    all_results[idx] = runBench(io, chain_label, chain_depth, benchChained, &scheduler, cfg, sample_buf);
    printResult(all_results[idx]);
    idx += 1;

    var fan_name_buf: [64]u8 = undefined;
    const fan_count = cfg.batchSize(64);
    const fan_label = std.fmt.bufPrint(&fan_name_buf, "fan-out-fan-in/{d}+1", .{fan_count}) catch "fan/?";
    all_results[idx] = runBench(io, fan_label, fan_count + 1, benchFanOutFanIn, &scheduler, cfg, sample_buf);
    printResult(all_results[idx]);
    idx += 1;

    std.debug.print("\n", .{});

    // --- Real-world patterns ---
    const frame_jobs = cfg.batchSize(28);
    std.debug.print("  [real-world patterns]\n", .{});
    printSeparator();

    var frame_name_buf: [64]u8 = undefined;
    const frame_label = std.fmt.bufPrint(&frame_name_buf, "pattern/game-frame ({d} jobs)", .{frame_jobs}) catch "pattern/?";
    all_results[idx] = runBench(io, frame_label, frame_jobs, benchGameFrame, &scheduler, cfg, sample_buf);
    printResult(all_results[idx]);
    idx += 1;

    std.debug.print("\n", .{});

    // --- Sustained throughput ---
    const sustained_total = cfg.batchSize(64) * 10;
    std.debug.print("  [sustained throughput — 10 waves]\n", .{});
    printSeparator();

    var sustained_name_buf: [64]u8 = undefined;
    const sustained_label = std.fmt.bufPrint(&sustained_name_buf, "throughput/sustained ({d} total jobs)", .{sustained_total}) catch "throughput/?";
    all_results[idx] = runBench(io, sustained_label, sustained_total, benchSustainedThroughput, &scheduler, cfg, sample_buf);
    printResult(all_results[idx]);
    idx += 1;

    // --- Summary ---
    printSummary(all_results[0..idx], cfg);
}
