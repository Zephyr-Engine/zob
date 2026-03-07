const std = @import("std");

pub fn CircularArray(comptime T: type) type {
    const cache_line = std.atomic.cache_line;

    return struct {
        const Self = @This();

        items: []align(cache_line) std.atomic.Value(T),
        previous: ?*Self,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, n: usize) !*Self {
            std.debug.assert(n > 0 and (n & (n - 1)) == 0); // must be power of 2

            const items = try allocator.alignedAlloc(
                std.atomic.Value(T),
                @enumFromInt(std.math.log2(@as(usize, cache_line))),
                n,
            );
            @memset(std.mem.sliceAsBytes(items), 0);

            const self = try allocator.create(Self);
            self.* = .{
                .items = items,
                .previous = null,
                .allocator = allocator,
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.previous) |prev| {
                prev.deinit();
            }
            self.allocator.free(self.items);
            self.allocator.destroy(self);
        }

        pub inline fn size(self: *const Self) usize {
            return self.items.len;
        }

        pub inline fn get(self: *const Self, index: usize) T {
            return self.items[index & (self.size() - 1)].load(.acquire);
        }

        pub inline fn put(self: *Self, index: usize, x: T) void {
            self.items[index & (self.size() - 1)].store(x, .release);
        }

        pub fn grow(self: *Self, top: usize, bottom: usize) !*Self {
            const new_array = try Self.init(self.allocator, self.size() * 2);
            new_array.previous = self;

            var i = top;
            while (i != bottom) : (i +%= 1) {
                new_array.put(i, self.get(i));
            }

            return new_array;
        }
    };
}

const testing = std.testing;

test "init creates array with correct size" {
    const arr = try CircularArray(u64).init(testing.allocator, 8);
    defer arr.deinit();

    try testing.expectEqual(@as(usize, 8), arr.size());
}

test "init requires power of 2" {
    // size must be power of 2 — non-power-of-2 should assert
    // We can't easily test assert failures, but we verify valid powers work.
    inline for ([_]usize{ 1, 2, 4, 8, 16, 32, 64, 128 }) |n| {
        const arr = try CircularArray(u64).init(testing.allocator, n);
        defer arr.deinit();
        try testing.expectEqual(n, arr.size());
    }
}

test "put and get basic" {
    const arr = try CircularArray(u64).init(testing.allocator, 4);
    defer arr.deinit();

    arr.put(0, 10);
    arr.put(1, 20);
    arr.put(2, 30);
    arr.put(3, 40);

    try testing.expectEqual(@as(u64, 10), arr.get(0));
    try testing.expectEqual(@as(u64, 20), arr.get(1));
    try testing.expectEqual(@as(u64, 30), arr.get(2));
    try testing.expectEqual(@as(u64, 40), arr.get(3));
}

test "put and get with wrapping" {
    const arr = try CircularArray(u64).init(testing.allocator, 4);
    defer arr.deinit();

    // Index 4 should wrap to index 0 (4 & 3 == 0)
    arr.put(0, 100);
    arr.put(4, 200);
    try testing.expectEqual(@as(u64, 200), arr.get(0));
    try testing.expectEqual(@as(u64, 200), arr.get(4));

    // Index 7 should wrap to index 3 (7 & 3 == 3)
    arr.put(7, 777);
    try testing.expectEqual(@as(u64, 777), arr.get(3));
    try testing.expectEqual(@as(u64, 777), arr.get(7));
}

test "initial values are zero" {
    const arr = try CircularArray(u64).init(testing.allocator, 8);
    defer arr.deinit();

    for (0..8) |i| {
        try testing.expectEqual(@as(u64, 0), arr.get(i));
    }
}

test "grow doubles size" {
    const arr = try CircularArray(u64).init(testing.allocator, 4);
    // no defer deinit — grown.deinit() frees arr via previous chain

    const grown = try arr.grow(0, 0);
    defer grown.deinit();

    try testing.expectEqual(@as(usize, 8), grown.size());
}

test "grow copies elements between top and bottom" {
    const arr = try CircularArray(u64).init(testing.allocator, 4);
    // no defer deinit — grown.deinit() frees arr via previous chain

    arr.put(0, 10);
    arr.put(1, 20);
    arr.put(2, 30);
    arr.put(3, 40);

    const grown = try arr.grow(0, 4);
    defer grown.deinit();

    try testing.expectEqual(@as(u64, 10), grown.get(0));
    try testing.expectEqual(@as(u64, 20), grown.get(1));
    try testing.expectEqual(@as(u64, 30), grown.get(2));
    try testing.expectEqual(@as(u64, 40), grown.get(3));
}

test "grow copies partial range" {
    const arr = try CircularArray(u64).init(testing.allocator, 4);

    arr.put(0, 100);
    arr.put(1, 200);
    arr.put(2, 300);
    arr.put(3, 400);

    // Only copy indices 1 and 2 (top=1, bottom=3)
    const grown = try arr.grow(1, 3);
    defer grown.deinit();

    try testing.expectEqual(@as(u64, 200), grown.get(1));
    try testing.expectEqual(@as(u64, 300), grown.get(2));
}

test "grow preserves previous pointer chain" {
    const arr = try CircularArray(u64).init(testing.allocator, 4);

    const grown1 = try arr.grow(0, 0);
    const grown2 = try grown1.grow(0, 0);
    defer grown2.deinit(); // should recursively free grown1 and arr

    try testing.expectEqual(@as(usize, 16), grown2.size());
    try testing.expect(grown2.previous != null);
    try testing.expect(grown2.previous.?.previous != null);
}

test "grow with wrapping indices" {
    const arr = try CircularArray(u64).init(testing.allocator, 4);

    // Simulate a deque scenario: top=3, bottom=6
    // Indices 3,4,5 should be copied. 4 wraps to 0, 5 wraps to 1.
    arr.put(3, 33);
    arr.put(0, 44); // index 4 wraps to 0
    arr.put(1, 55); // index 5 wraps to 1

    const grown = try arr.grow(3, 6);
    defer grown.deinit();

    try testing.expectEqual(@as(u64, 33), grown.get(3));
    try testing.expectEqual(@as(u64, 44), grown.get(4));
    try testing.expectEqual(@as(u64, 55), grown.get(5));
}

test "works with different types" {
    // Test with i32
    {
        const arr = try CircularArray(i32).init(testing.allocator, 4);
        defer arr.deinit();

        arr.put(0, -42);
        try testing.expectEqual(@as(i32, -42), arr.get(0));
    }

    // Test with u8
    {
        const arr = try CircularArray(u8).init(testing.allocator, 2);
        defer arr.deinit();

        arr.put(0, 255);
        try testing.expectEqual(@as(u8, 255), arr.get(0));
    }
}

test "size 1 array wraps all indices to 0" {
    const arr = try CircularArray(u64).init(testing.allocator, 1);
    defer arr.deinit();

    arr.put(0, 42);
    try testing.expectEqual(@as(u64, 42), arr.get(0));
    try testing.expectEqual(@as(u64, 42), arr.get(1));
    try testing.expectEqual(@as(u64, 42), arr.get(999));
}

test "overwrite values" {
    const arr = try CircularArray(u64).init(testing.allocator, 4);
    defer arr.deinit();

    arr.put(0, 1);
    try testing.expectEqual(@as(u64, 1), arr.get(0));

    arr.put(0, 2);
    try testing.expectEqual(@as(u64, 2), arr.get(0));

    arr.put(0, 3);
    try testing.expectEqual(@as(u64, 3), arr.get(0));
}

test "grow with empty range is valid" {
    const arr = try CircularArray(u64).init(testing.allocator, 4);

    arr.put(0, 99);

    // top == bottom means empty range, nothing to copy
    const grown = try arr.grow(5, 5);
    defer grown.deinit();

    try testing.expectEqual(@as(usize, 8), grown.size());
    // The value at index 0 should be 0 (not copied)
    try testing.expectEqual(@as(u64, 0), grown.get(0));
}

test "large index wrapping" {
    const arr = try CircularArray(u64).init(testing.allocator, 8);
    defer arr.deinit();

    // Very large index should still wrap correctly
    const large_idx: usize = std.math.maxInt(usize);
    arr.put(large_idx, 42);

    // large_idx & 7 gives us the wrapped position
    const expected_slot = large_idx & 7;
    try testing.expectEqual(@as(u64, 42), arr.get(expected_slot));
    try testing.expectEqual(@as(u64, 42), arr.get(large_idx));
}
