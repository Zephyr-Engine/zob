# zob (Zephyr Job)

A high-performance async job framework for Zig 0.16, built on `std.Io`.

Designed for the [Zephyr Game Engine](https://github.com/your-org/zephyr) but fully standalone — usable in any Zig project that needs structured async work.

## Features

- **Comptime job validation** — jobs are plain structs with `pub fn execute`. Invalid types produce clear compile errors.
- **Single and batch submission** — `submit()` for one job, `submitBatch()` for many of the same type.
- **Future-based results** — `Future.await(io)` blocks the task (not the thread) until the result is ready.
- **Error propagation** — if `execute` returns an error union, the error flows through the Future naturally.
- **Priority levels** — high, normal, low (advisory in v0.1.0).
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


