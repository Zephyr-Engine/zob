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

// --- Tests ---

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

test "submit single job" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sched = Scheduler.init(io, testing.allocator);
    var future = sched.submit(AddJob, .{ .a = 3, .b = 4 }, .normal);
    const result = future.await(io);
    try testing.expectEqual(@as(i32, 7), result);
}

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
