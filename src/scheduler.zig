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

    pub const Options = struct {
        max_concurrency: usize = 0,
    };

    const QueuedJob = struct {
        priority: Priority,
        context: *anyopaque,
        run: *const fn (*anyopaque) void,
    };

    io: Io,
    allocator: std.mem.Allocator,
    max_concurrency: usize,
    mutex: Io.Mutex = .init,
    group: Io.Group = .init,
    queued: std.ArrayList(QueuedJob) = .empty,
    active: usize = 0,
    dispatching: bool = false,

    pub fn init(io: Io, allocator: std.mem.Allocator) Self {
        return initWithOptions(io, allocator, .{});
    }

    pub fn initWithOptions(io: Io, allocator: std.mem.Allocator, options: Options) Self {
        return .{
            .io = io,
            .allocator = allocator,
            .max_concurrency = if (options.max_concurrency == 0) std.math.maxInt(usize) else options.max_concurrency,
        };
    }

    /// Waits for running work to finish and frees the scheduler's queue.
    /// All returned futures must be awaited or cancelled before this call.
    pub fn deinit(self: *Self) void {
        self.group.await(self.io) catch unreachable;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.queued.items.len == 0);
        std.debug.assert(self.active == 0);
        self.queued.deinit(self.allocator);
    }

    /// Submit a single job. Higher-priority pending jobs start first; jobs
    /// already running are never preempted.
    pub fn submit(
        self: *Self,
        comptime T: type,
        data: T,
        priority: Priority,
    ) Future(job.JobResult(T)) {
        return self.trySubmit(T, data, priority) catch @panic("zob scheduler out of memory");
    }

    pub fn trySubmit(
        self: *Self,
        comptime T: type,
        data: T,
        priority: Priority,
    ) !Future(job.JobResult(T)) {
        if (self.max_concurrency == std.math.maxInt(usize)) {
            const runner = comptime job.makeRunner(T);
            return Future(job.JobResult(T)).fromIoFuture(self.dispatchDirect(runner, .{data}));
        }

        const Result = job.JobResult(T);
        const completion = try future_mod.State(Result).create(self.allocator);
        errdefer self.allocator.destroy(completion);

        const state = try self.allocator.create(JobState(T));
        errdefer self.allocator.destroy(state);
        state.* = .{
            .scheduler = self,
            .completion = completion,
            .data = data,
        };

        try self.enqueue(.{
            .priority = priority,
            .context = state,
            .run = JobState(T).run,
        });
        return Future(Result).init(completion);
    }

    /// Submit a batch with a comptime-known size. This avoids allocating the
    /// futures buffer; bounded schedulers still allocate queued-job state.
    pub fn submitInlineBatch(
        self: *Self,
        comptime T: type,
        comptime N: usize,
        items: *const [N]T,
        priority: Priority,
    ) InlineBatchFuture(job.JobResult(T), N) {
        var result: InlineBatchFuture(job.JobResult(T), N) = undefined;
        result.len = N;
        for (items, 0..) |item, i| {
            result.futures[i] = self.submit(T, item, priority);
        }
        return result;
    }

    /// Submit a batch into a caller-provided futures buffer. This avoids
    /// allocating the futures buffer; bounded schedulers still allocate queued-job state.
    pub fn submitBatchBuf(
        self: *Self,
        comptime T: type,
        items: []const T,
        priority: Priority,
        buf: []Future(job.JobResult(T)),
    ) []Future(job.JobResult(T)) {
        const len = @min(items.len, buf.len);
        for (items[0..len], 0..) |item, i| {
            buf[i] = self.submit(T, item, priority);
        }
        return buf[0..len];
    }

    /// Submit a batch, heap-allocating the futures slice. Caller-provided or
    /// inline futures buffers avoid this slice allocation.
    pub fn submitBatch(
        self: *Self,
        comptime T: type,
        items: []const T,
        priority: Priority,
    ) !BatchFuture(job.JobResult(T)) {
        const Result = job.JobResult(T);

        var futures = try self.allocator.alloc(Future(Result), items.len);
        var submitted: usize = 0;
        errdefer {
            for (futures[0..submitted]) |*future| {
                if (comptime @typeInfo(Result) == .error_union) {
                    _ = future.cancel(self.io) catch {};
                } else {
                    _ = future.cancel(self.io);
                }
            }
            self.allocator.free(futures);
        }

        for (items, 0..) |item, i| {
            futures[i] = try self.trySubmit(T, item, priority);
            submitted += 1;
        }

        return .{ .futures = futures, .allocator = self.allocator };
    }

    fn JobState(comptime T: type) type {
        const Result = job.JobResult(T);
        return struct {
            scheduler: *Scheduler,
            completion: *future_mod.State(Result),
            data: T,

            fn run(context: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                const scheduler = self.scheduler;
                const result = self.data.execute();
                self.completion.resolve(scheduler.io, result);
                scheduler.allocator.destroy(self);
                scheduler.finishJob();
            }
        };
    }

    fn enqueue(self: *Self, queued_job: QueuedJob) !void {
        self.mutex.lockUncancelable(self.io);
        errdefer self.mutex.unlock(self.io);
        try self.queued.append(self.allocator, queued_job);
        self.mutex.unlock(self.io);
        self.kick();
    }

    fn finishJob(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        self.active -= 1;
        self.mutex.unlock(self.io);
        self.kick();
    }

    fn kick(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        if (self.dispatching) {
            self.mutex.unlock(self.io);
            return;
        }
        self.dispatching = true;
        self.mutex.unlock(self.io);

        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.active == self.max_concurrency or self.queued.items.len == 0) {
                self.dispatching = false;
                self.mutex.unlock(self.io);
                return;
            }
            const next = self.takeHighestPriorityLocked();
            self.active += 1;
            self.mutex.unlock(self.io);

            self.dispatch(next);
        }
    }

    fn takeHighestPriorityLocked(self: *Self) QueuedJob {
        var best_index: usize = 0;
        for (self.queued.items[1..], 1..) |queued_job, index| {
            if (@intFromEnum(queued_job.priority) < @intFromEnum(self.queued.items[best_index].priority)) {
                best_index = index;
            }
        }
        return self.queued.orderedRemove(best_index);
    }

    fn dispatch(self: *Self, queued_job: QueuedJob) void {
        self.group.concurrent(self.io, runQueuedJob, .{queued_job}) catch {
            self.group.async(self.io, runQueuedJob, .{queued_job});
        };
    }

    /// `Io.concurrent` can be temporarily unavailable even after earlier
    /// successes. Fall back for this submission rather than assuming that
    /// concurrency support is permanent.
    fn dispatchDirect(self: *Self, comptime func: anytype, args: anytype) Io.Future(@typeInfo(@TypeOf(@as(@TypeOf(func), func))).@"fn".return_type.?) {
        return self.io.concurrent(func, args) catch self.io.async(func, args);
    }

    fn runQueuedJob(queued_job: QueuedJob) Io.Cancelable!void {
        queued_job.run(queued_job.context);
    }
};

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

    // Await in reverse order to test independence
    const r3 = f3.await(io);
    const r2 = f2.await(io);
    const r1 = f1.await(io);

    try testing.expectEqual(@as(i32, 3), r1);
    try testing.expectEqual(@as(i32, 7), r2);
    try testing.expectEqual(@as(i32, 11), r3);
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

    var buf: [2]Future(i32) = undefined;
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
    var buf: [2]Future(i32) = undefined;
    const futures = sched.submitBatchBuf(AddJob, &items, .normal, &buf);

    try testing.expectEqual(@as(usize, 2), futures.len);

    var results: [2]i32 = undefined;
    for (futures, 0..) |*f, i| {
        results[i] = f.await(io);
    }

    try testing.expectEqual(@as(i32, 2), results[0]);
    try testing.expectEqual(@as(i32, 4), results[1]);
}

// --- concurrent dispatch tests ---

const AtomicCounter = struct {
    value: std.atomic.Value(u32),

    fn init() AtomicCounter {
        return .{ .value = std.atomic.Value(u32).init(0) };
    }

    fn increment(self: *AtomicCounter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    fn load(self: *AtomicCounter) u32 {
        return self.value.load(.monotonic);
    }
};

var concurrent_counter: AtomicCounter = AtomicCounter.init();

const CountingJob = struct {
    pub fn execute(self: @This()) void {
        _ = self;
        concurrent_counter.increment();
    }
};

test "dispatch uses concurrent with Io.Threaded" {
    concurrent_counter = AtomicCounter.init();

    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    // Submit multiple jobs — with Io.Threaded, dispatch should use concurrent
    var f1 = sched.submit(CountingJob, .{}, .normal);
    var f2 = sched.submit(CountingJob, .{}, .normal);
    var f3 = sched.submit(CountingJob, .{}, .normal);
    var f4 = sched.submit(CountingJob, .{}, .normal);

    f1.await(io);
    f2.await(io);
    f3.await(io);
    f4.await(io);

    // All 4 jobs completed — concurrent or async, result is the same
    try testing.expectEqual(@as(u32, 4), concurrent_counter.load());
}

var concurrent_sum: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

const AtomicAddJob = struct {
    value: i64,

    pub fn execute(self: @This()) i64 {
        _ = self.value;
        _ = concurrent_sum.fetchAdd(self.value, .monotonic);
        return self.value;
    }
};

test "concurrent dispatch produces correct results across many jobs" {
    concurrent_sum = std.atomic.Value(i64).init(0);

    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    const n = 64;
    var items: [n]AtomicAddJob = undefined;
    for (&items, 0..) |*item, i| {
        item.* = .{ .value = @intCast(i + 1) };
    }

    var batch = try sched.submitBatch(AtomicAddJob, &items, .high);
    defer batch.deinit();

    const results = try batch.awaitAll(io);
    defer testing.allocator.free(results);

    // Each job returns its own value
    for (results, 0..) |r, i| {
        try testing.expectEqual(@as(i64, @intCast(i + 1)), r);
    }

    // Atomic sum should equal 1+2+...+64 = 2080
    try testing.expectEqual(@as(i64, (n * (n + 1)) / 2), concurrent_sum.load(.monotonic));
}

test "concurrent dispatch with inline batch" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]SquareJob{
        .{ .value = 5 },
        .{ .value = 6 },
        .{ .value = 7 },
        .{ .value = 8 },
    };

    var batch = sched.submitInlineBatch(SquareJob, 4, &items, .normal);
    const results = batch.awaitAll(io);

    try testing.expectEqual(@as(i32, 25), results[0]);
    try testing.expectEqual(@as(i32, 36), results[1]);
    try testing.expectEqual(@as(i32, 49), results[2]);
    try testing.expectEqual(@as(i32, 64), results[3]);
}

test "concurrent dispatch with batchBuf" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    const items = [_]AddJob{
        .{ .a = 10, .b = 10 },
        .{ .a = 20, .b = 20 },
        .{ .a = 30, .b = 30 },
    };

    var buf: [3]Future(i32) = undefined;
    const futures = sched.submitBatchBuf(AddJob, &items, .high, &buf);

    var results: [3]i32 = undefined;
    for (futures, 0..) |*f, i| {
        results[i] = f.await(io);
    }

    try testing.expectEqual(@as(i32, 20), results[0]);
    try testing.expectEqual(@as(i32, 40), results[1]);
    try testing.expectEqual(@as(i32, 60), results[2]);
}

test "concurrent dispatch error propagation" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);

    // Success case
    var f_ok = sched.submit(FailableJob, .{ .should_fail = false }, .high);
    const ok_result = try f_ok.await(io);
    try testing.expectEqual(@as(i32, 77), ok_result);

    // Error case
    var f_err = sched.submit(FailableJob, .{ .should_fail = true }, .high);
    try testing.expectError(error.TestFail, f_err.await(io));
}

test "concurrent dispatch cancel" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var future = sched.submit(AddJob, .{ .a = 42, .b = 8 }, .normal);
    const result = future.cancel(io);
    try testing.expectEqual(@as(i32, 50), result);
}

const OrderedContext = struct {
    io: Io,
    gate: Io.Semaphore = .{},
    started: Io.Semaphore = .{},
    mutex: Io.Mutex = .init,
    order: [3]u8 = undefined,
    len: usize = 0,

    fn append(self: *OrderedContext, value: u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.order[self.len] = value;
        self.len += 1;
    }
};

const OrderedJob = struct {
    context: *OrderedContext,
    value: u8,
    blocks: bool = false,

    pub fn execute(self: @This()) void {
        self.context.append(self.value);
        if (self.blocks) {
            self.context.started.post(self.context.io);
            self.context.gate.waitUncancelable(self.context.io);
        }
    }
};

test "bounded scheduler starts pending jobs by priority" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Scheduler.initWithOptions(io, testing.allocator, .{ .max_concurrency = 1 });
    defer scheduler.deinit();
    var context = OrderedContext{ .io = io };

    var first = scheduler.submit(OrderedJob, .{ .context = &context, .value = 1, .blocks = true }, .low);
    context.started.waitUncancelable(io);
    var normal = scheduler.submit(OrderedJob, .{ .context = &context, .value = 2 }, .normal);
    var high = scheduler.submit(OrderedJob, .{ .context = &context, .value = 3 }, .high);

    context.gate.post(io);
    first.await(io);
    high.await(io);
    normal.await(io);

    try testing.expectEqualSlices(u8, &.{ 1, 3, 2 }, context.order[0..context.len]);
}

const ConcurrencyContext = struct {
    io: Io,
    release: Io.Semaphore = .{},
    started: Io.Semaphore = .{},
    mutex: Io.Mutex = .init,
    active: usize = 0,
    peak: usize = 0,

    fn begin(self: *ConcurrencyContext) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active += 1;
        self.peak = @max(self.peak, self.active);
    }

    fn end(self: *ConcurrencyContext) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active -= 1;
    }
};

const LimitedJob = struct {
    context: *ConcurrencyContext,

    pub fn execute(self: @This()) void {
        self.context.begin();
        self.context.started.post(self.context.io);
        self.context.release.waitUncancelable(self.context.io);
        self.context.end();
    }
};

test "bounded scheduler limits concurrent job bodies" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Scheduler.initWithOptions(io, testing.allocator, .{ .max_concurrency = 2 });
    defer scheduler.deinit();
    var context = ConcurrencyContext{ .io = io };

    var first = scheduler.submit(LimitedJob, .{ .context = &context }, .normal);
    var second = scheduler.submit(LimitedJob, .{ .context = &context }, .normal);
    var third = scheduler.submit(LimitedJob, .{ .context = &context }, .normal);

    context.started.waitUncancelable(io);
    context.started.waitUncancelable(io);
    try testing.expectEqual(@as(usize, 2), context.peak);

    context.release.post(io);
    context.release.post(io);
    context.release.post(io);
    first.await(io);
    second.await(io);
    third.await(io);

    try testing.expectEqual(@as(usize, 2), context.peak);
}
