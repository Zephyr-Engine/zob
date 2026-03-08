const std = @import("std");
const Io = std.Io;
const job = @import("job.zig");
const future_mod = @import("future.zig");
const Priority = @import("priority.zig").Priority;

pub const Future = future_mod.Future;
pub const BatchFuture = future_mod.BatchFuture;
pub const InlineBatchFuture = future_mod.InlineBatchFuture;

pub const Scheduler = struct {
    const Self = @This();

    io: Io,
    allocator: std.mem.Allocator,
    active_high: std.atomic.Value(u32),
    active_normal: std.atomic.Value(u32),

    pub fn init(io: Io, allocator: std.mem.Allocator) Self {
        return .{
            .io = io,
            .allocator = allocator,
            .active_high = std.atomic.Value(u32).init(0),
            .active_normal = std.atomic.Value(u32).init(0),
        };
    }

    /// Submit a single job for async execution.
    /// High priority: always dispatched immediately (zero overhead fast path).
    /// Normal priority: deferred if high-priority work is in-flight.
    /// Low priority: deferred if high or normal-priority work is in-flight.
    pub fn submit(
        self: *Self,
        comptime T: type,
        data: T,
        priority: Priority,
    ) Future(job.JobResult(T)) {
        const Result = job.JobResult(T);

        const should_defer = switch (priority) {
            .high => false,
            .normal => self.active_high.load(.acquire) > 0,
            .low => self.active_high.load(.acquire) > 0 or
                self.active_normal.load(.acquire) > 0,
        };

        if (should_defer) {
            const Typed = DeferredFor(T, Result);
            const d = self.allocator.create(Typed) catch {
                // Fallback: dispatch immediately on allocation failure
                return self.submitImmediate(T, data, priority);
            };
            d.* = .{
                .base = .{
                    .dispatch = Typed.dispatch,
                    .execute = Typed.execute,
                    .destroy = Typed.destroy,
                },
                .data = data,
                .scheduler = self,
                .priority = priority,
            };
            return .{ .state = .{ .deferred = .{
                .d = &d.base,
                .allocator = self.allocator,
            } } };
        }

        return self.submitImmediate(T, data, priority);
    }

    fn submitImmediate(
        self: *Self,
        comptime T: type,
        data: T,
        priority: Priority,
    ) Future(job.JobResult(T)) {
        const runner = comptime makeCountedRunner(T, job.JobResult(T));
        self.incrementActive(priority);
        return .{ .state = .{ .immediate = self.io.async(runner, .{ data, self, priority }) } };
    }

    /// Submit a batch with a comptime-known size. Zero heap allocations.
    /// This is the fastest path for fixed-size batches.
    /// Always dispatches immediately (no deferred dispatch for batch APIs).
    pub fn submitInlineBatch(
        self: *Self,
        comptime T: type,
        comptime N: usize,
        items: *const [N]T,
        priority: Priority,
    ) InlineBatchFuture(job.JobResult(T), N) {
        const Result = job.JobResult(T);
        const runner = comptime makeCountedRunner(T, Result);
        var result: InlineBatchFuture(Result, N) = undefined;
        result.len = N;
        for (items, 0..) |item, i| {
            self.incrementActive(priority);
            result.futures[i] = self.io.async(runner, .{ item, self, priority });
        }
        return result;
    }

    /// Submit a batch into a caller-provided futures buffer. Zero heap allocations.
    /// Buffer must be at least items.len. Returns the used portion.
    /// Always dispatches immediately (no deferred dispatch for batch APIs).
    pub fn submitBatchBuf(
        self: *Self,
        comptime T: type,
        items: []const T,
        priority: Priority,
        buf: []Io.Future(job.JobResult(T)),
    ) []Io.Future(job.JobResult(T)) {
        const Result = job.JobResult(T);
        const runner = comptime makeCountedRunner(T, Result);
        const len = @min(items.len, buf.len);
        for (items[0..len], 0..) |item, i| {
            self.incrementActive(priority);
            buf[i] = self.io.async(runner, .{ item, self, priority });
        }
        return buf[0..len];
    }

    /// Submit a batch, heap-allocating the futures slice.
    /// For zero-alloc alternatives, use submitInlineBatch or submitBatchBuf.
    /// Always dispatches immediately (no deferred dispatch for batch APIs).
    pub fn submitBatch(
        self: *Self,
        comptime T: type,
        items: []const T,
        priority: Priority,
    ) !BatchFuture(job.JobResult(T)) {
        const Result = job.JobResult(T);
        const runner = comptime makeCountedRunner(T, Result);

        var futures = try self.allocator.alloc(Io.Future(Result), items.len);
        errdefer self.allocator.free(futures);

        for (items, 0..) |item, i| {
            self.incrementActive(priority);
            futures[i] = self.io.async(runner, .{ item, self, priority });
        }

        return .{ .futures = futures, .allocator = self.allocator };
    }

    fn incrementActive(self: *Self, priority: Priority) void {
        switch (priority) {
            .high => _ = self.active_high.fetchAdd(1, .release),
            .normal => _ = self.active_normal.fetchAdd(1, .release),
            .low => {}, // nothing defers behind low
        }
    }

    pub fn decrementActive(self: *Self, priority: Priority) void {
        switch (priority) {
            .high => _ = self.active_high.fetchSub(1, .release),
            .normal => _ = self.active_normal.fetchSub(1, .release),
            .low => {},
        }
    }
};

/// Creates a runner function that decrements the scheduler's active counter
/// when the job completes. Used for all dispatched jobs.
fn makeCountedRunner(comptime T: type, comptime Result: type) fn (T, *Scheduler, Priority) Result {
    return struct {
        fn run(data: T, sched: *Scheduler, prio: Priority) Result {
            defer sched.decrementActive(prio);
            return data.execute();
        }
    }.run;
}

/// Creates a type-erased deferred dispatch wrapper for a specific job type.
/// Allocated on the heap when a job is deferred due to priority enforcement.
fn DeferredFor(comptime T: type, comptime Result: type) type {
    return struct {
        base: Future(Result).Deferred,
        data: T,
        scheduler: *Scheduler,
        priority: Priority,

        fn dispatch(base_ptr: *Future(Result).Deferred, io: Io) Io.Future(Result) {
            const self: *@This() = @fieldParentPtr("base", base_ptr);

            // Wait until higher-priority work has completed before dispatching
            switch (self.priority) {
                .high => {},
                .normal => {
                    while (self.scheduler.active_high.load(.acquire) > 0) {
                        std.atomic.spinLoopHint();
                    }
                },
                .low => {
                    while (self.scheduler.active_high.load(.acquire) > 0 or
                        self.scheduler.active_normal.load(.acquire) > 0)
                    {
                        std.atomic.spinLoopHint();
                    }
                },
            }

            self.scheduler.incrementActive(self.priority);
            const runner = comptime makeCountedRunner(T, Result);
            return io.async(runner, .{ self.data, self.scheduler, self.priority });
        }

        fn execute(base_ptr: *Future(Result).Deferred) Result {
            const self: *@This() = @fieldParentPtr("base", base_ptr);
            return self.data.execute();
        }

        fn destroy(base_ptr: *Future(Result).Deferred, allocator: std.mem.Allocator) void {
            const self: *@This() = @fieldParentPtr("base", base_ptr);
            allocator.destroy(self);
        }
    };
}

const testing = std.testing;

const AddJob = struct {
    a: i32,
    b: i32,

    pub fn execute(self: @This()) i32 {
        return self.a + self.b;
    }
};

const SquareJob = struct {
    value: i32,

    pub fn execute(self: @This()) i32 {
        return self.value * self.value;
    }
};

const FailableJob = struct {
    should_fail: bool,

    pub fn execute(self: @This()) error{TestFail}!i32 {
        if (self.should_fail) return error.TestFail;
        return 77;
    }
};

const VoidJob = struct {
    pub fn execute(self: @This()) void {
        _ = self;
    }
};

const IdentityJob = struct {
    value: i64,

    pub fn execute(self: @This()) i64 {
        return self.value;
    }
};

// --- submit tests ---

test "submit single job" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var future = sched.submit(AddJob, .{ .a = 3, .b = 4 }, .normal);
    const result = future.await(io);
    try testing.expectEqual(@as(i32, 7), result);
}

test "submit with high priority" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var future = sched.submit(AddJob, .{ .a = 10, .b = 20 }, .high);
    try testing.expectEqual(@as(i32, 30), future.await(io));
}

test "submit with low priority" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var future = sched.submit(AddJob, .{ .a = 5, .b = 5 }, .low);
    try testing.expectEqual(@as(i32, 10), future.await(io));
}

test "submit void job" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var future = sched.submit(VoidJob, .{}, .normal);
    future.await(io);
}

test "submit error propagation success" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var future = sched.submit(FailableJob, .{ .should_fail = false }, .normal);
    const result = try future.await(io);
    try testing.expectEqual(@as(i32, 77), result);
}

test "submit error propagation failure" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var future = sched.submit(FailableJob, .{ .should_fail = true }, .normal);
    try testing.expectError(error.TestFail, future.await(io));
}

test "submit cancel returns result" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var future = sched.submit(AddJob, .{ .a = 100, .b = 200 }, .normal);
    const result = future.cancel(io);
    try testing.expectEqual(@as(i32, 300), result);
}

test "submit chained jobs via data flow" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    var f1 = sched.submit(AddJob, .{ .a = 10, .b = 20 }, .high);
    const r1 = f1.await(io);

    var f2 = sched.submit(SquareJob, .{ .value = r1 }, .high);
    const r2 = f2.await(io);

    // (10 + 20)^2 = 900
    try testing.expectEqual(@as(i32, 900), r2);
}

test "submit multiple independent jobs" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    var f1 = sched.submit(AddJob, .{ .a = 1, .b = 2 }, .high);
    var f2 = sched.submit(AddJob, .{ .a = 3, .b = 4 }, .normal);
    var f3 = sched.submit(AddJob, .{ .a = 5, .b = 6 }, .low);

    // Await in priority order for correct priority enforcement
    const r1 = f1.await(io);
    const r2 = f2.await(io);
    const r3 = f3.await(io);

    try testing.expectEqual(@as(i32, 3), r1);
    try testing.expectEqual(@as(i32, 7), r2);
    try testing.expectEqual(@as(i32, 11), r3);
}

// --- priority enforcement tests ---

test "normal job deferred when high is active" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    // Submit high-priority job (dispatched immediately)
    var f_high = sched.submit(AddJob, .{ .a = 1, .b = 1 }, .high);

    // Submit normal-priority job (should be deferred since high is active)
    var f_normal = sched.submit(AddJob, .{ .a = 10, .b = 20 }, .normal);

    // Await high first (clears active_high counter)
    const r1 = f_high.await(io);
    try testing.expectEqual(@as(i32, 2), r1);

    // Now await normal (dispatches since high is done)
    const r2 = f_normal.await(io);
    try testing.expectEqual(@as(i32, 30), r2);
}

test "low job deferred when normal is active" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    // Submit normal-priority job (no high active, dispatches immediately)
    var f_normal = sched.submit(AddJob, .{ .a = 5, .b = 5 }, .normal);

    // Submit low-priority job (should be deferred since normal is active)
    var f_low = sched.submit(AddJob, .{ .a = 100, .b = 1 }, .low);

    // Await normal first
    const r1 = f_normal.await(io);
    try testing.expectEqual(@as(i32, 10), r1);

    // Now await low
    const r2 = f_low.await(io);
    try testing.expectEqual(@as(i32, 101), r2);
}

test "cancel deferred future runs synchronously" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    // Submit high so normal gets deferred
    var f_high = sched.submit(AddJob, .{ .a = 1, .b = 1 }, .high);

    // Normal is deferred
    var f_normal = sched.submit(AddJob, .{ .a = 50, .b = 50 }, .normal);

    // Cancel the deferred future (runs synchronously, no thread pool)
    const result = f_normal.cancel(io);
    try testing.expectEqual(@as(i32, 100), result);

    // Clean up high
    _ = f_high.await(io);
}

test "high priority always dispatches immediately" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    // Multiple high-priority jobs should all dispatch immediately
    var f1 = sched.submit(AddJob, .{ .a = 1, .b = 1 }, .high);
    var f2 = sched.submit(AddJob, .{ .a = 2, .b = 2 }, .high);
    var f3 = sched.submit(AddJob, .{ .a = 3, .b = 3 }, .high);

    try testing.expectEqual(@as(i32, 2), f1.await(io));
    try testing.expectEqual(@as(i32, 4), f2.await(io));
    try testing.expectEqual(@as(i32, 6), f3.await(io));
}

test "active counters reach zero after all jobs complete" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    var f1 = sched.submit(AddJob, .{ .a = 1, .b = 1 }, .high);
    var f2 = sched.submit(AddJob, .{ .a = 2, .b = 2 }, .normal);

    _ = f1.await(io);
    _ = f2.await(io);

    try testing.expectEqual(@as(u32, 0), sched.active_high.load(.acquire));
    try testing.expectEqual(@as(u32, 0), sched.active_normal.load(.acquire));
}

// --- submitBatch tests ---

test "submitBatch heap-allocated" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]SquareJob{
        .{ .value = 1 },
        .{ .value = 2 },
        .{ .value = 3 },
    };

    var batch = try sched.submitBatch(SquareJob, &items, .high);
    defer batch.deinit();

    const results = try batch.awaitAll(io);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(i32, 1), results[0]);
    try testing.expectEqual(@as(i32, 4), results[1]);
    try testing.expectEqual(@as(i32, 9), results[2]);
}

test "submitBatch single item" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]AddJob{.{ .a = 99, .b = 1 }};

    var batch = try sched.submitBatch(AddJob, &items, .normal);
    defer batch.deinit();

    const results = try batch.awaitAll(io);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(i32, 100), results[0]);
}

test "submitBatch error propagation" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]FailableJob{
        .{ .should_fail = false },
        .{ .should_fail = true },
        .{ .should_fail = false },
    };

    var batch = try sched.submitBatch(FailableJob, &items, .normal);
    defer batch.deinit();

    try testing.expectError(error.TestFail, batch.awaitAll(io));
}

test "submitBatch awaitAllBuf" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]SquareJob{
        .{ .value = 3 },
        .{ .value = 4 },
        .{ .value = 5 },
    };

    var batch = try sched.submitBatch(SquareJob, &items, .normal);
    defer batch.deinit();

    var buf: [3]i32 = undefined;
    const results = batch.awaitAllBuf(io, &buf);

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqual(@as(i32, 9), results[0]);
    try testing.expectEqual(@as(i32, 16), results[1]);
    try testing.expectEqual(@as(i32, 25), results[2]);
}

test "submitBatch larger batch (32 items)" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var items: [32]IdentityJob = undefined;
    for (&items, 0..) |*item, i| {
        item.* = .{ .value = @intCast(i) };
    }

    var batch = try sched.submitBatch(IdentityJob, &items, .normal);
    defer batch.deinit();

    const results = try batch.awaitAll(io);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 32), results.len);
    for (results, 0..) |r, i| {
        try testing.expectEqual(@as(i64, @intCast(i)), r);
    }
}

// --- submitInlineBatch tests ---

test "submitInlineBatch zero-alloc" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]SquareJob{
        .{ .value = 2 },
        .{ .value = 3 },
        .{ .value = 4 },
    };

    var batch = sched.submitInlineBatch(SquareJob, 3, &items, .high);
    const results = batch.awaitAll(io);

    try testing.expectEqual(@as(i32, 4), results[0]);
    try testing.expectEqual(@as(i32, 9), results[1]);
    try testing.expectEqual(@as(i32, 16), results[2]);
}

test "submitInlineBatch single item" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]AddJob{.{ .a = 42, .b = 58 }};

    var batch = sched.submitInlineBatch(AddJob, 1, &items, .normal);
    const results = batch.awaitAll(io);

    try testing.expectEqual(@as(i32, 100), results[0]);
}

test "submitInlineBatch awaitAllBuf" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]AddJob{
        .{ .a = 10, .b = 1 },
        .{ .a = 20, .b = 2 },
    };

    var batch = sched.submitInlineBatch(AddJob, 2, &items, .low);
    var buf: [2]i32 = undefined;
    const results = batch.awaitAllBuf(io, &buf);

    try testing.expectEqual(@as(i32, 11), results[0]);
    try testing.expectEqual(@as(i32, 22), results[1]);
}

// --- submitBatchBuf tests ---

test "submitBatchBuf zero-alloc" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]AddJob{
        .{ .a = 1, .b = 2 },
        .{ .a = 3, .b = 4 },
    };

    var buf: [2]Io.Future(i32) = undefined;
    const futures = sched.submitBatchBuf(AddJob, &items, .normal, &buf);

    var results: [2]i32 = undefined;
    for (futures, 0..) |*f, i| {
        results[i] = f.await(io);
    }

    try testing.expectEqual(@as(i32, 3), results[0]);
    try testing.expectEqual(@as(i32, 7), results[1]);
}

test "submitBatchBuf truncates to buffer size" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]AddJob{
        .{ .a = 1, .b = 1 },
        .{ .a = 2, .b = 2 },
        .{ .a = 3, .b = 3 },
        .{ .a = 4, .b = 4 },
    };

    // Buffer smaller than items — should only process 2
    var buf: [2]Io.Future(i32) = undefined;
    const futures = sched.submitBatchBuf(AddJob, &items, .normal, &buf);

    try testing.expectEqual(@as(usize, 2), futures.len);

    var results: [2]i32 = undefined;
    for (futures, 0..) |*f, i| {
        results[i] = f.await(io);
    }

    try testing.expectEqual(@as(i32, 2), results[0]);
    try testing.expectEqual(@as(i32, 4), results[1]);
}
