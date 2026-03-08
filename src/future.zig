const std = @import("std");
const Io = std.Io;

pub fn Future(comptime Result: type) type {
    return struct {
        const Self = @This();

        pub const Deferred = struct {
            dispatch: *const fn (*Deferred, Io) Io.Future(Result),
            execute: *const fn (*Deferred) Result,
            destroy: *const fn (*Deferred, std.mem.Allocator) void,
        };

        state: union(enum) {
            immediate: Io.Future(Result),
            deferred: struct {
                d: *Deferred,
                allocator: std.mem.Allocator,
            },
        },

        pub fn await(self: *Self, io: Io) Result {
            switch (self.state) {
                .deferred => |info| {
                    const io_future = info.d.dispatch(info.d, io);
                    info.d.destroy(info.d, info.allocator);
                    self.state = .{ .immediate = io_future };
                },
                .immediate => {},
            }
            switch (self.state) {
                .immediate => |*f| return f.await(io),
                .deferred => unreachable,
            }
        }

        pub fn cancel(self: *Self, io: Io) Result {
            switch (self.state) {
                .deferred => |info| {
                    // Run synchronously — skip thread pool entirely
                    const result = info.d.execute(info.d);
                    info.d.destroy(info.d, info.allocator);
                    return result;
                },
                .immediate => |*f| return f.cancel(io),
            }
        }
    };
}

pub fn BatchFuture(comptime Result: type) type {
    return struct {
        const Self = @This();
        const Clean = UnwrapErrorUnion(Result);

        futures: []Io.Future(Result),
        allocator: std.mem.Allocator,

        pub fn awaitAllBuf(self: *Self, io: Io, results: []Clean) []Clean {
            const len = @min(self.futures.len, results.len);
            for (self.futures[0..len], 0..) |*f, i| {
                const r = f.await(io);
                results[i] = if (Result == Clean) r else r catch unreachable;
            }
            return results[0..len];
        }

        pub fn awaitAll(self: *Self, io: Io) ![]Clean {
            var results = try self.allocator.alloc(Clean, self.futures.len);
            errdefer self.allocator.free(results);

            for (self.futures, 0..) |*f, i| {
                const r = f.await(io);
                if (Result != Clean) {
                    results[i] = r catch |err| {
                        // Cancel remaining futures to avoid leaks
                        for (self.futures[i + 1 ..]) |*remaining| {
                            _ = remaining.cancel(io) catch {};
                        }
                        return err;
                    };
                } else {
                    results[i] = r;
                }
            }

            return results;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.futures);
        }
    };
}

pub fn InlineBatchFuture(comptime Result: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Clean = UnwrapErrorUnion(Result);

        futures: [capacity]Io.Future(Result),
        len: usize,

        pub fn awaitAllBuf(self: *Self, io: Io, results: []Clean) []Clean {
            const len = @min(self.len, results.len);
            for (self.futures[0..len], 0..) |*f, i| {
                const r = f.await(io);
                results[i] = if (Result == Clean) r else r catch unreachable;
            }
            return results[0..len];
        }

        pub fn awaitAll(self: *Self, io: Io) [capacity]Clean {
            var results: [capacity]Clean = undefined;
            for (self.futures[0..self.len], 0..) |*f, i| {
                const r = f.await(io);
                results[i] = if (Result == Clean) r else r catch unreachable;
            }
            return results;
        }
    };
}

pub fn UnwrapErrorUnion(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}

// --- Tests ---

const testing = std.testing;

const DoubleJob = struct {
    value: i32,
    pub fn execute(self: @This()) i32 {
        return self.value * 2;
    }
};

const FailJob = struct {
    should_fail: bool,
    pub fn execute(self: @This()) error{Boom}!i32 {
        if (self.should_fail) return error.Boom;
        return 99;
    }
};

const VoidJob = struct {
    pub fn execute(self: @This()) void {
        _ = self;
    }
};

const runner_double = struct {
    fn run(j: DoubleJob) i32 {
        return j.execute();
    }
}.run;

const runner_fail = struct {
    fn run(j: FailJob) error{Boom}!i32 {
        return j.execute();
    }
}.run;

// --- Future tests ---

test "Future.await returns correct result" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var f: Future(i32) = .{ .state = .{ .immediate = io.async(runner_double, .{DoubleJob{ .value = 7 }}) } };
    const result = f.await(io);
    try testing.expectEqual(@as(i32, 14), result);
}

test "Future.cancel returns result" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var f: Future(i32) = .{ .state = .{ .immediate = io.async(runner_double, .{DoubleJob{ .value = 5 }}) } };
    const result = f.cancel(io);
    try testing.expectEqual(@as(i32, 10), result);
}

test "Future.await propagates error" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var f: Future(error{Boom}!i32) = .{ .state = .{ .immediate = io.async(runner_fail, .{FailJob{ .should_fail = true }}) } };
    try testing.expectError(error.Boom, f.await(io));
}

test "Future.await returns success from fallible job" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var f: Future(error{Boom}!i32) = .{ .state = .{ .immediate = io.async(runner_fail, .{FailJob{ .should_fail = false }}) } };
    const result = try f.await(io);
    try testing.expectEqual(@as(i32, 99), result);
}

// --- BatchFuture tests ---

test "BatchFuture.awaitAll returns correct results" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var futures = try testing.allocator.alloc(Io.Future(i32), 3);
    futures[0] = io.async(runner_double, .{DoubleJob{ .value = 1 }});
    futures[1] = io.async(runner_double, .{DoubleJob{ .value = 2 }});
    futures[2] = io.async(runner_double, .{DoubleJob{ .value = 3 }});

    var batch: BatchFuture(i32) = .{ .futures = futures, .allocator = testing.allocator };
    defer batch.deinit();

    const results = try batch.awaitAll(io);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(i32, 2), results[0]);
    try testing.expectEqual(@as(i32, 4), results[1]);
    try testing.expectEqual(@as(i32, 6), results[2]);
}

test "BatchFuture.awaitAllBuf writes into caller buffer" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var futures = try testing.allocator.alloc(Io.Future(i32), 2);
    futures[0] = io.async(runner_double, .{DoubleJob{ .value = 10 }});
    futures[1] = io.async(runner_double, .{DoubleJob{ .value = 20 }});

    var batch: BatchFuture(i32) = .{ .futures = futures, .allocator = testing.allocator };
    defer batch.deinit();

    var buf: [2]i32 = undefined;
    const results = batch.awaitAllBuf(io, &buf);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqual(@as(i32, 20), results[0]);
    try testing.expectEqual(@as(i32, 40), results[1]);
}

test "BatchFuture.awaitAll propagates error from fallible job" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var futures = try testing.allocator.alloc(Io.Future(error{Boom}!i32), 2);
    futures[0] = io.async(runner_fail, .{FailJob{ .should_fail = false }});
    futures[1] = io.async(runner_fail, .{FailJob{ .should_fail = true }});

    var batch: BatchFuture(error{Boom}!i32) = .{ .futures = futures, .allocator = testing.allocator };
    defer batch.deinit();

    try testing.expectError(error.Boom, batch.awaitAll(io));
}

test "BatchFuture with single element" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var futures = try testing.allocator.alloc(Io.Future(i32), 1);
    futures[0] = io.async(runner_double, .{DoubleJob{ .value = 50 }});

    var batch: BatchFuture(i32) = .{ .futures = futures, .allocator = testing.allocator };
    defer batch.deinit();

    const results = try batch.awaitAll(io);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(i32, 100), results[0]);
}

// --- InlineBatchFuture tests ---

test "InlineBatchFuture.awaitAll returns inline array" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var batch: InlineBatchFuture(i32, 3) = undefined;
    batch.len = 3;
    batch.futures[0] = io.async(runner_double, .{DoubleJob{ .value = 4 }});
    batch.futures[1] = io.async(runner_double, .{DoubleJob{ .value = 5 }});
    batch.futures[2] = io.async(runner_double, .{DoubleJob{ .value = 6 }});

    const results = batch.awaitAll(io);

    try testing.expectEqual(@as(i32, 8), results[0]);
    try testing.expectEqual(@as(i32, 10), results[1]);
    try testing.expectEqual(@as(i32, 12), results[2]);
}

test "InlineBatchFuture.awaitAllBuf writes into caller buffer" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var batch: InlineBatchFuture(i32, 2) = undefined;
    batch.len = 2;
    batch.futures[0] = io.async(runner_double, .{DoubleJob{ .value = 7 }});
    batch.futures[1] = io.async(runner_double, .{DoubleJob{ .value = 8 }});

    var buf: [2]i32 = undefined;
    const results = batch.awaitAllBuf(io, &buf);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqual(@as(i32, 14), results[0]);
    try testing.expectEqual(@as(i32, 16), results[1]);
}

test "InlineBatchFuture with single element" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var batch: InlineBatchFuture(i32, 1) = undefined;
    batch.len = 1;
    batch.futures[0] = io.async(runner_double, .{DoubleJob{ .value = 25 }});

    const results = batch.awaitAll(io);
    try testing.expectEqual(@as(i32, 50), results[0]);
}

// --- UnwrapErrorUnion tests ---

test "UnwrapErrorUnion unwraps error union" {
    try testing.expect(UnwrapErrorUnion(error{Foo}!i32) == i32);
    try testing.expect(UnwrapErrorUnion(anyerror!u64) == u64);
}

test "UnwrapErrorUnion passes through non-error types" {
    try testing.expect(UnwrapErrorUnion(i32) == i32);
    try testing.expect(UnwrapErrorUnion(void) == void);
    try testing.expect(UnwrapErrorUnion(u64) == u64);
}
