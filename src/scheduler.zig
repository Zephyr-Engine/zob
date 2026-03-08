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

    pub fn init(io: Io, allocator: std.mem.Allocator) Self {
        return .{
            .io = io,
            .allocator = allocator,
        };
    }

    /// Submit a single job for async execution.
    pub fn submit(
        self: *Self,
        comptime T: type,
        data: T,
        priority: Priority,
    ) Future(job.JobResult(T)) {
        _ = priority;
        const runner = comptime job.makeRunner(T);
        const handle = self.io.async(runner, .{data});
        return .{ .inner = handle };
    }

    /// Submit a batch with a comptime-known size. Zero heap allocations.
    /// This is the fastest path for fixed-size batches.
    pub fn submitInlineBatch(
        self: *Self,
        comptime T: type,
        comptime N: usize,
        items: *const [N]T,
        priority: Priority,
    ) InlineBatchFuture(job.JobResult(T), N) {
        _ = priority;
        const runner = comptime job.makeRunner(T);
        var result: InlineBatchFuture(job.JobResult(T), N) = undefined;
        result.len = N;
        for (items, 0..) |item, i| {
            result.futures[i] = self.io.async(runner, .{item});
        }
        return result;
    }

    /// Submit a batch into a caller-provided futures buffer. Zero heap allocations.
    /// Buffer must be at least items.len. Returns the used portion.
    pub fn submitBatchBuf(
        self: *Self,
        comptime T: type,
        items: []const T,
        priority: Priority,
        buf: []Io.Future(job.JobResult(T)),
    ) []Io.Future(job.JobResult(T)) {
        _ = priority;
        const runner = comptime job.makeRunner(T);
        const len = @min(items.len, buf.len);
        for (items[0..len], 0..) |item, i| {
            buf[i] = self.io.async(runner, .{item});
        }
        return buf[0..len];
    }

    /// Submit a batch, heap-allocating the futures slice.
    /// For zero-alloc alternatives, use submitInlineBatch or submitBatchBuf.
    pub fn submitBatch(
        self: *Self,
        comptime T: type,
        items: []const T,
        priority: Priority,
    ) !BatchFuture(job.JobResult(T)) {
        _ = priority;
        const Result = job.JobResult(T);
        const runner = comptime job.makeRunner(T);

        var futures = try self.allocator.alloc(Io.Future(Result), items.len);
        errdefer self.allocator.free(futures);

        for (items, 0..) |item, i| {
            futures[i] = self.io.async(runner, .{item});
        }

        return .{ .futures = futures, .allocator = self.allocator };
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
