const std = @import("std");
const zob = @import("zob");

const AddJob = struct {
    a: i64,
    b: i64,

    pub fn execute(self: @This()) i64 {
        return self.a + self.b;
    }
};

const MultiplyJob = struct {
    value: i64,
    factor: i64,

    pub fn execute(self: @This()) i64 {
        return self.value * self.factor;
    }
};

const SlowJob = struct {
    id: u32,

    pub fn execute(self: @This()) u32 {
        var sum: u64 = 0;
        for (0..1_000_000_000) |i| {
            sum +%= i *% self.id;
        }
        std.debug.print("SlowJob {d} completed (sum={d})\n", .{ self.id, sum });
        return self.id;
    }
};

const FallibleJob = struct {
    should_fail: bool,

    pub fn execute(self: @This()) !i64 {
        if (self.should_fail) return error.JobFailed;
        return 42;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var scheduler = zob.Scheduler.init(io, allocator);

    // Example 1: Simple single job
    std.debug.print("--- Example 1: Single job ---\n", .{});

    var add_future = scheduler.submit(AddJob, .{ .a = 10, .b = 20 }, .normal);
    const sum = add_future.await(io);
    std.debug.print("10 + 20 = {d}\n\n", .{sum});

    // Example 2: Chained dependencies via data flow
    std.debug.print("--- Example 2: Chained jobs ---\n", .{});

    var step1 = scheduler.submit(AddJob, .{ .a = 10, .b = 20 }, .high);
    const step1_result = step1.await(io);

    var step2 = scheduler.submit(MultiplyJob, .{
        .value = step1_result,
        .factor = 3,
    }, .high);
    const step2_result = step2.await(io);
    std.debug.print("(10 + 20) * 3 = {d}\n\n", .{step2_result});

    // Example 3: Parallel fan-out batch
    std.debug.print("--- Example 3: Parallel batch ---\n", .{});

    var add_items: [4]AddJob = undefined;
    for (0..4) |i| {
        add_items[i] = .{
            .a = @intCast(i * 10),
            .b = @intCast(i * 10 + 5),
        };
    }

    var batch = try scheduler.submitBatch(AddJob, &add_items, .normal);
    defer batch.deinit();
    const results = try batch.awaitAll(io);
    defer allocator.free(results);

    for (results, 0..) |r, i| {
        std.debug.print("batch[{d}] = {d}\n", .{ i, r });
    }
    std.debug.print("\n", .{});

    // Example 4: Fan-out then fan-in (map-reduce)
    std.debug.print("--- Example 4: Fan-out / fan-in ---\n", .{});

    var items: [3]AddJob = .{
        .{ .a = 1, .b = 2 },
        .{ .a = 3, .b = 4 },
        .{ .a = 5, .b = 6 },
    };

    var fan = try scheduler.submitBatch(AddJob, &items, .high);
    defer fan.deinit();
    const partial = try fan.awaitAll(io);
    defer allocator.free(partial);

    var total: i64 = 0;
    for (partial) |v| total += v;
    std.debug.print("(1+2) + (3+4) + (5+6) = {d}\n\n", .{total});

    // Example 5: Mixed priorities
    std.debug.print("--- Example 5: Mixed priorities ---\n", .{});

    var low = scheduler.submit(SlowJob, .{ .id = 1 }, .low);
    var high = scheduler.submit(SlowJob, .{ .id = 2 }, .high);
    var normal = scheduler.submit(SlowJob, .{ .id = 3 }, .normal);

    const high_r = high.await(io);
    std.debug.print("high priority result: {d}\n", .{high_r});
    const normal_r = normal.await(io);
    std.debug.print("normal priority result: {d}\n", .{normal_r});
    const low_r = low.await(io);
    std.debug.print("low priority result: {d}\n\n", .{low_r});

    // Example 6: Error propagation
    std.debug.print("--- Example 6: Error propagation ---\n", .{});

    var ok_future = scheduler.submit(FallibleJob, .{ .should_fail = false }, .normal);
    const ok_result = try ok_future.await(io);
    std.debug.print("ok job returned: {d}\n", .{ok_result});

    var fail_future = scheduler.submit(FallibleJob, .{ .should_fail = true }, .normal);
    if (fail_future.await(io)) |_| {
        std.debug.print("ERROR: should have failed!\n", .{});
    } else |err| {
        std.debug.print("failing job correctly returned error: {}\n", .{err});
    }

    // Example 7: Fire and forget
    std.debug.print("\n--- Example 7: Fire and forget ---\n", .{});

    var bg = scheduler.submit(AddJob, .{ .a = 999, .b = 1 }, .low);
    std.debug.print("submitted background work, not awaiting result yet...\n", .{});
    // In real code you'd cancel or await before shutdown to avoid leaks
    _ = bg.cancel(io);
}
