# zob (Zephyr Job)

A high-performance async job framework for Zig 0.16, built on `std.Io`.

Designed for the [Zephyr Game Engine](https://github.com/your-org/zephyr) but fully standalone — usable in any Zig project that needs structured async work.

## Features

- **Comptime job validation** — jobs are plain structs with `pub fn execute`. Invalid types produce clear compile errors.
- **Single and batch submission** — `submit()` for one job, `submitBatch()` for many of the same type.
- **Zero-allocation hot path** — `submitInlineBatch()` and `submitBatchBuf()` avoid all heap allocations for game-loop-friendly performance.
- **Future-based results** — `Future.await(io)` blocks the task (not the thread) until the result is ready.
- **Error propagation** — if `execute` returns an error union, the error flows through the Future naturally.
- **Priority levels** — high, normal, low.
- **Zero dependencies** — built entirely on `std.Io`, no custom thread pool or runtime.

## Requirements
- Zig 0.16+ 

## Installing

Add zob as a dependency in your `build.zig.zon`:

```zig
zig fetch --save git+https://github.com:Zephyr-Engine/zob.git
```

Then in your `build.zig`:

```zig
const zob_dep = b.dependency("zob", .{
    .target = target,
    .optimize = optimize,
});
const zob_mod = zob_dep.module("zob");
exe.root_module.addImport("zob", zob_mod);
```

## Running the example

```sh
zig build example
```

## Running tests

```sh
zig build test --summary all
```

## Priority Levels

| Priority | Intended use |
|----------|-------------|
| `.high` | Frame-critical work: physics, animation, visibility |
| `.normal` | Standard work: AI, scripting, audio |
| `.low` | Deferrable background work: streaming, compression |

## Usage

### Defining a job

A job is any struct with a `pub fn execute(self: @This()) ReturnType` method:

```zig
const AddJob = struct {
    a: i64,
    b: i64,

    pub fn execute(self: @This()) i64 {
        return self.a + self.b;
    }
};
```

Jobs can return error unions too:

```zig
const FallibleJob = struct {
    should_fail: bool,

    pub fn execute(self: @This()) !i64 {
        if (self.should_fail) return error.JobFailed;
        return 42;
    }
};
```

### Creating a scheduler

```zig
const zob = @import("zob");

pub fn main(init: std.process.Init) !void {
    var scheduler = zob.Scheduler.init(init.io, init.gpa);
    // ...
}
```

### Submitting a single job

```zig
var future = scheduler.submit(AddJob, .{ .a = 10, .b = 32 }, .normal);
const result = future.await(io);
// result == 42
```

### Submitting a batch

```zig
const items = [_]AddJob{
    .{ .a = 1, .b = 2 },
    .{ .a = 3, .b = 4 },
    .{ .a = 5, .b = 6 },
};

var batch = try scheduler.submitBatch(AddJob, &items, .normal);
defer batch.deinit();

const results = try batch.awaitAll(io);
defer allocator.free(results);
// results == [3, 7, 11]
```

### Chaining jobs (data dependencies)

```zig
var step1 = scheduler.submit(AddJob, .{ .a = 10, .b = 20 }, .high);
const sum = step1.await(io);

var step2 = scheduler.submit(MultiplyJob, .{ .value = sum, .factor = 3 }, .high);
const product = step2.await(io);
// product == 90
```

### Error handling

```zig
var future = scheduler.submit(FallibleJob, .{ .should_fail = true }, .normal);
if (future.await(io)) |val| {
    // success
    _ = val;
} else |err| {
    // err == error.JobFailed
    _ = err;
}
```

### Cancellation

```zig
var future = scheduler.submit(SomeJob, .{...}, .low);
_ = future.cancel(io); // request cancellation and wait for completion
```

### Zero-allocation batches

For performance-critical code (game loops, real-time systems), use the zero-allocation APIs to avoid touching the heap entirely:

**Comptime-known batch size — `submitInlineBatch`:**

Everything lives on the stack. No allocator needed.

```zig
const jobs = [_]PhysicsJob{
    .{ .body_id = 0 },
    .{ .body_id = 1 },
    .{ .body_id = 2 },
    .{ .body_id = 3 },
};

// Zero heap allocations — futures are inline in the returned struct
var batch = scheduler.submitInlineBatch(PhysicsJob, 4, &jobs, .high);

// awaitAll returns a stack-allocated [4]Result — also zero allocations
const results = batch.awaitAll(io);
```

**Runtime-sized batch with caller-provided buffer — `submitBatchBuf`:**

```zig
var future_buf: [64]std.Io.Future(u64) = undefined;
const futures = scheduler.submitBatchBuf(ComputeJob, items, .normal, &future_buf);

var result_buf: [64]u64 = undefined;
for (futures, 0..) |*f, i| {
    result_buf[i] = f.await(io);
}
```

**Results into a caller buffer — `awaitAllBuf`:**

```zig
var batch = try scheduler.submitBatch(MyJob, items, .normal);
defer batch.deinit();

var result_buf: [128]i64 = undefined;
const results = batch.awaitAllBuf(io, &result_buf); // no allocation for results
```

### API summary

| Method | Futures alloc | Results alloc | Best for |
|--------|:---:|:---:|------|
| `submitBatch` + `awaitAll` | heap | heap | Dynamic sizes, convenience |
| `submitBatch` + `awaitAllBuf` | heap | none | Dynamic batch, known max results |
| `submitInlineBatch` + `awaitAll` | none | none | Comptime-known batch size (fastest) |
| `submitBatchBuf` | none | manual | Full control, zero-alloc hot path |

## Benchmarks

Run the built-in benchmark suite:

```sh
zig build bench
```

### Configuration

All parameters are optional:

```sh
zig build bench -- [options]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--scale=N` | 1 | Batch size multiplier |
| `--work=N` | 100 | Loop iterations per job (controls job weight) |
| `--iters=N` | 20 | Measured samples per benchmark |
| `--warmup=N` | 5 | Warmup iterations before measuring |

### Scale presets

| Scale | Batch sizes | Use case |
|-------|------------|----------|
| 1 | 16 – 512 | Quick sanity check |
| 4 | 64 – 2048 | Moderate stress |
| 16 | 256 – 8192 | Heavy stress test |
| 64 | 1024 – 32768 | Extreme load |

### Examples

```sh
zig build bench                              # defaults
zig build bench -- --scale=4                 # 4x batch sizes
zig build bench -- --scale=16 --work=1000    # heavy stress, ~10us/job
zig build bench -- --scale=64 --iters=50     # extreme, more samples
zig build bench -- --work=10000              # very heavy jobs (~100us each)
```

### What it measures

- **Single job overhead** — round-trip cost of `submit` + `await` for a no-op
- **Batch scaling** — how per-op cost changes from 16 to 512+ jobs
- **Dependency chains** — sequential job-to-job latency
- **Fan-out / fan-in** — parallel scatter-gather pattern
- **Game frame simulation** — mixed-priority batches (physics + AI + audio)
- **Sustained throughput** — 10 consecutive waves of batches

