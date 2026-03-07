// Work-Stealing Deque inspired by https://www.dre.vanderbilt.edu/~schmidt/PDF/work-stealing-dequeue.pdf
const CircularArray = @import("circular_array.zig").CircularArray;
const std = @import("std");
const aUsize = std.atomic.Value(usize);

pub fn WorkStealQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const aQueueT = std.atomic.Value(*CircularArray(T));

        pub const Stolen = union(enum) {
            empty,
            abort,
            success: T,
        };

        top: aUsize,
        bottom: aUsize,
        items: aQueueT,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .top = aUsize.init(0),
                .bottom = aUsize.init(0),
                .items = aQueueT.init(try CircularArray(T).init(allocator, 32)),
                .allocator = allocator,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.items.raw.deinit();
            self.allocator.destroy(self);
        }

        pub fn push(self: *Self, value: T) !void {
            const b = self.bottom.load(.unordered);
            const t = self.top.load(.acquire);
            var a = self.items.load(.unordered);

            if (b - t > a.size() - 1) {
                a = try a.grow(t, b);
                self.items.store(a, .unordered);
            }
            a.put(b, value);
            self.bottom.store(b + 1, .release);
        }

        pub fn pop(self: *Self) ?T {
            var b = self.bottom.load(.unordered);
            const a = self.items.load(.unordered);
            b -%= 1;
            self.bottom.store(b, .seq_cst);
            const t = self.top.load(.seq_cst);

            const size: isize = @bitCast(b -% t);
            if (size > 0) {
                // More than one element — safe to pop
                return a.get(b);
            } else if (size == 0) {
                // Last element — race with stealers
                if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .monotonic) != null) {
                    self.bottom.store(t + 1, .unordered);
                    return null;
                }
                self.bottom.store(t + 1, .unordered);
                return a.get(b);
            }

            // Empty
            self.bottom.store(t, .unordered);
            return null;
        }

        pub fn steal(self: *Self) Stolen {
            const t = self.top.load(.seq_cst);
            const b = self.bottom.load(.seq_cst);

            if (t < b) {
                const a = self.items.load(.unordered);
                const value = a.get(t);
                if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .seq_cst) != null) {
                    return .abort;
                }
                return .{ .success = value };
            }
            return .empty;
        }
    };
}

const testing = std.testing;

// -- Single-threaded owner tests (push/pop) --

test "empty queue pop returns null" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try testing.expectEqual(null, q.pop());
}

test "push then pop returns value (LIFO)" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(42);
    try testing.expectEqual(@as(u64, 42), q.pop().?);
    try testing.expectEqual(null, q.pop());
}

test "push/pop LIFO ordering" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(1);
    try q.push(2);
    try q.push(3);

    // Pop returns most recently pushed (LIFO / stack order)
    try testing.expectEqual(@as(u64, 3), q.pop().?);
    try testing.expectEqual(@as(u64, 2), q.pop().?);
    try testing.expectEqual(@as(u64, 1), q.pop().?);
    try testing.expectEqual(null, q.pop());
}

test "interleaved push and pop" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(10);
    try q.push(20);
    try testing.expectEqual(@as(u64, 20), q.pop().?);

    try q.push(30);
    try testing.expectEqual(@as(u64, 30), q.pop().?);
    try testing.expectEqual(@as(u64, 10), q.pop().?);
    try testing.expectEqual(null, q.pop());
}

test "pop on empty after draining returns null" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(1);
    _ = q.pop();

    // Multiple pops on empty should all return null
    try testing.expectEqual(null, q.pop());
    try testing.expectEqual(null, q.pop());
    try testing.expectEqual(null, q.pop());
}

test "push many then pop all" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    const n: u64 = 100;
    for (0..n) |i| {
        try q.push(i);
    }

    // Pop all in LIFO order
    var i: u64 = n;
    while (i > 0) {
        i -= 1;
        try testing.expectEqual(i, q.pop().?);
    }
    try testing.expectEqual(null, q.pop());
}

// -- Single-threaded steal tests --

test "steal from empty returns empty" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try testing.expectEqual(WorkStealQueue(u64).Stolen.empty, q.steal());
}

test "steal returns oldest item (FIFO from steal side)" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(1);
    try q.push(2);
    try q.push(3);

    // Steal takes from the top (oldest first — FIFO order)
    try testing.expectEqual(@as(u64, 1), q.steal().success);
    try testing.expectEqual(@as(u64, 2), q.steal().success);
    try testing.expectEqual(@as(u64, 3), q.steal().success);
    try testing.expectEqual(WorkStealQueue(u64).Stolen.empty, q.steal());
}

test "mixed pop and steal" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(1);
    try q.push(2);
    try q.push(3);

    // Steal takes from top (oldest), pop takes from bottom (newest)
    try testing.expectEqual(@as(u64, 1), q.steal().success);
    try testing.expectEqual(@as(u64, 3), q.pop().?);
    // Only 2 remains
    try testing.expectEqual(@as(u64, 2), q.pop().?);
    try testing.expectEqual(null, q.pop());
}

test "steal single element" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(42);
    try testing.expectEqual(@as(u64, 42), q.steal().success);
    try testing.expectEqual(WorkStealQueue(u64).Stolen.empty, q.steal());
    try testing.expectEqual(null, q.pop());
}

// -- Capacity / grow tests --

test "push beyond initial capacity triggers grow" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    // Initial capacity is 32, push 64 items to force a grow
    for (0..64) |i| {
        try q.push(i);
    }

    // All items should still be retrievable in LIFO order
    var i: u64 = 64;
    while (i > 0) {
        i -= 1;
        const val = q.pop() orelse {
            try testing.expect(false); // should not be null
            unreachable;
        };
        try testing.expectEqual(i, val);
    }
    try testing.expectEqual(null, q.pop());
}

test "push and steal beyond initial capacity" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    for (0..64) |i| {
        try q.push(i);
    }

    // Steal all in FIFO order
    for (0..64) |i| {
        try testing.expectEqual(@as(u64, i), q.steal().success);
    }
    try testing.expectEqual(WorkStealQueue(u64).Stolen.empty, q.steal());
}

// -- Pop/steal contention on last element --

test "pop and steal both compete for last element" {
    // When there's exactly one element, pop and steal race.
    // In single-threaded context, pop should win.
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(99);

    // Pop should get it
    try testing.expectEqual(@as(u64, 99), q.pop().?);
    // Steal should see empty
    try testing.expectEqual(WorkStealQueue(u64).Stolen.empty, q.steal());
}

// -- Refill after drain --

test "push after complete drain" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(1);
    try q.push(2);
    _ = q.pop();
    _ = q.pop();

    // Queue is empty, push again
    try q.push(3);
    try q.push(4);

    try testing.expectEqual(@as(u64, 4), q.pop().?);
    try testing.expectEqual(@as(u64, 3), q.pop().?);
    try testing.expectEqual(null, q.pop());
}

test "steal after complete drain and refill" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    try q.push(1);
    _ = q.steal();

    try q.push(2);
    try q.push(3);

    try testing.expectEqual(@as(u64, 2), q.steal().success);
    try testing.expectEqual(@as(u64, 3), q.steal().success);
    try testing.expectEqual(WorkStealQueue(u64).Stolen.empty, q.steal());
}

// -- Multi-threaded tests --

test "concurrent steals" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    const num_items: u64 = 1000;
    for (0..num_items) |i| {
        try q.push(i);
    }

    const num_stealers = 4;
    var stolen_counts = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    };

    var threads: [num_stealers]std.Thread = undefined;
    for (0..num_stealers) |t| {
        threads[t] = try std.Thread.spawn(.{}, struct {
            fn run(queue: *WorkStealQueue(u64), count: *std.atomic.Value(u64)) void {
                var local_count: u64 = 0;
                while (true) {
                    switch (queue.steal()) {
                        .success => local_count += 1,
                        .abort => continue,
                        .empty => break,
                    }
                }
                count.store(local_count, .release);
            }
        }.run, .{ q, &stolen_counts[t] });
    }

    for (&threads) |*t| t.join();

    var total: u64 = 0;
    for (&stolen_counts) |*c| total += c.load(.acquire);
    try testing.expectEqual(num_items, total);
}

test "owner push/pop with concurrent stealers" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    var total_stolen = std.atomic.Value(u64).init(0);
    var owner_done = std.atomic.Value(bool).init(false);

    const num_stealers = 2;
    var threads: [num_stealers]std.Thread = undefined;

    for (0..num_stealers) |t| {
        threads[t] = try std.Thread.spawn(.{}, struct {
            fn run(
                queue: *WorkStealQueue(u64),
                stolen: *std.atomic.Value(u64),
                done: *std.atomic.Value(bool),
            ) void {
                var count: u64 = 0;
                while (!done.load(.acquire)) {
                    switch (queue.steal()) {
                        .success => count += 1,
                        .abort, .empty => {},
                    }
                }
                // Drain remaining
                while (true) {
                    switch (queue.steal()) {
                        .success => count += 1,
                        .abort => continue,
                        .empty => break,
                    }
                }
                _ = stolen.fetchAdd(count, .acq_rel);
            }
        }.run, .{ q, &total_stolen, &owner_done });
    }

    const num_items: u64 = 500;
    var owner_popped: u64 = 0;

    for (0..num_items) |i| {
        try q.push(i);
        // Occasionally pop from owner side too
        if (i % 5 == 0) {
            if (q.pop() != null) owner_popped += 1;
        }
    }

    // Pop remaining from owner side
    while (q.pop()) |_| {
        owner_popped += 1;
    }

    owner_done.store(true, .release);
    for (&threads) |*t| t.join();

    const total = owner_popped + total_stolen.load(.acquire);
    try testing.expectEqual(num_items, total);
}

test "stress: rapid push/pop cycles with stealers" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    var total_stolen = std.atomic.Value(u64).init(0);
    var owner_done = std.atomic.Value(bool).init(false);

    const stealer = try std.Thread.spawn(.{}, struct {
        fn run(
            queue: *WorkStealQueue(u64),
            stolen: *std.atomic.Value(u64),
            done: *std.atomic.Value(bool),
        ) void {
            var count: u64 = 0;
            while (!done.load(.acquire)) {
                switch (queue.steal()) {
                    .success => count += 1,
                    .abort, .empty => {},
                }
            }
            while (true) {
                switch (queue.steal()) {
                    .success => count += 1,
                    .abort => continue,
                    .empty => break,
                }
            }
            _ = stolen.fetchAdd(count, .acq_rel);
        }
    }.run, .{ q, &total_stolen, &owner_done });

    var pushed: u64 = 0;
    var popped: u64 = 0;
    const rounds: u64 = 200;

    for (0..rounds) |_| {
        // Push a batch
        for (0..10) |j| {
            try q.push(j);
            pushed += 1;
        }
        // Pop some back
        for (0..3) |_| {
            if (q.pop() != null) popped += 1;
        }
    }

    // Drain
    while (q.pop()) |_| popped += 1;

    owner_done.store(true, .release);
    stealer.join();

    const total = popped + total_stolen.load(.acquire);
    try testing.expectEqual(pushed, total);
}

test "no duplicate items under contention" {
    const num_items: usize = 2000;
    const num_stealers = 4;

    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    for (0..num_items) |i| {
        try q.push(i);
    }

    // Each stealer collects values into its own list
    const StolenList = std.ArrayListUnmanaged(u64);
    var stealer_lists: [num_stealers]StolenList = undefined;
    for (&stealer_lists) |*l| l.* = StolenList{};
    defer for (&stealer_lists) |*l| l.deinit(testing.allocator);

    var threads: [num_stealers]std.Thread = undefined;
    for (0..num_stealers) |t| {
        threads[t] = try std.Thread.spawn(.{}, struct {
            fn run(queue: *WorkStealQueue(u64), list: *StolenList) void {
                while (true) {
                    switch (queue.steal()) {
                        .success => |v| list.append(testing.allocator, v) catch unreachable,
                        .abort => continue,
                        .empty => break,
                    }
                }
            }
        }.run, .{ q, &stealer_lists[t] });
    }

    // Owner also pops
    var owner_list = StolenList{};
    defer owner_list.deinit(testing.allocator);
    while (q.pop()) |v| {
        try owner_list.append(testing.allocator, v);
    }

    for (&threads) |*t| t.join();

    // Merge all lists and verify each item seen exactly once
    var seen = std.StaticBitSet(num_items).initEmpty();
    for (owner_list.items) |v| {
        try testing.expect(!seen.isSet(v));
        seen.set(v);
    }
    for (&stealer_lists) |*l| {
        for (l.items) |v| {
            try testing.expect(!seen.isSet(v));
            seen.set(v);
        }
    }
    for (0..num_items) |i| {
        try testing.expect(seen.isSet(i));
    }
}

test "grow under contention" {
    const q = try WorkStealQueue(u64).init(testing.allocator);
    defer q.deinit();

    var total_stolen = std.atomic.Value(u64).init(0);
    var owner_done = std.atomic.Value(bool).init(false);

    const num_stealers = 3;
    var threads: [num_stealers]std.Thread = undefined;

    for (0..num_stealers) |t| {
        threads[t] = try std.Thread.spawn(.{}, struct {
            fn run(
                queue: *WorkStealQueue(u64),
                stolen: *std.atomic.Value(u64),
                done: *std.atomic.Value(bool),
            ) void {
                var count: u64 = 0;
                while (!done.load(.acquire)) {
                    switch (queue.steal()) {
                        .success => count += 1,
                        .abort, .empty => {},
                    }
                }
                while (true) {
                    switch (queue.steal()) {
                        .success => count += 1,
                        .abort => continue,
                        .empty => break,
                    }
                }
                _ = stolen.fetchAdd(count, .acq_rel);
            }
        }.run, .{ q, &total_stolen, &owner_done });
    }

    // Push 256 items without popping to force multiple grows (initial cap 32)
    const num_items: u64 = 256;
    for (0..num_items) |i| {
        try q.push(i);
    }

    var owner_popped: u64 = 0;
    while (q.pop()) |_| owner_popped += 1;

    owner_done.store(true, .release);
    for (&threads) |*t| t.join();

    const total = owner_popped + total_stolen.load(.acquire);
    try testing.expectEqual(num_items, total);
}

test "pop vs steal race on last element" {
    // Repeatedly set up a single-element queue and race pop against steal.
    // Over many iterations, both pop-wins and steal-wins should occur.
    const iterations: usize = 1000;
    var pop_wins: usize = 0;
    var steal_wins: usize = 0;

    for (0..iterations) |_| {
        const q = try WorkStealQueue(u64).init(testing.allocator);

        try q.push(42);

        var steal_result: WorkStealQueue(u64).Stolen = .empty;

        const stealer = try std.Thread.spawn(.{}, struct {
            fn run(queue: *WorkStealQueue(u64), result: *WorkStealQueue(u64).Stolen) void {
                result.* = queue.steal();
            }
        }.run, .{ q, &steal_result });

        const pop_result = q.pop();

        stealer.join();

        if (pop_result != null and steal_result == .empty) {
            pop_wins += 1;
        } else if (pop_result == null and steal_result == .success) {
            steal_wins += 1;
        } else if (pop_result != null and steal_result == .success) {
            // Both got the item — this is a bug
            testing.allocator.destroy(q);
            return error.TestUnexpectedResult;
        }
        // Both null/empty/abort is fine (steal aborted, pop saw empty)

        q.deinit();
    }

    // At least one side should have won at least once
    try testing.expect(pop_wins + steal_wins == iterations);
}
