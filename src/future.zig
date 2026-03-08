const std = @import("std");
const Io = std.Io;

/// A thin wrapper around std.Io.Future.
/// Identical layout — zero overhead.
pub fn Future(comptime Result: type) type {
    return struct {
        const Self = @This();

        inner: Io.Future(Result),

        pub fn await(self: *Self, io: Io) Result {
            return self.inner.await(io);
        }

        pub fn cancel(self: *Self, io: Io) Result {
            return self.inner.cancel(io);
        }
    };
}

/// Heap-allocated batch of futures. Use when batch size is runtime-known.
/// For comptime-known sizes, prefer InlineBatchFuture.
pub fn BatchFuture(comptime Result: type) type {
    return struct {
        const Self = @This();
        const Clean = UnwrapErrorUnion(Result);

        futures: []Io.Future(Result),
        allocator: std.mem.Allocator,

        /// Await all results, writing into a caller-provided buffer.
        /// Zero allocations.
        pub fn awaitAllBuf(self: *Self, io: Io, results: []Clean) []Clean {
            const len = @min(self.futures.len, results.len);
            for (self.futures[0..len], 0..) |*f, i| {
                const r = f.await(io);
                results[i] = if (Result == Clean) r else r catch unreachable;
            }
            return results[0..len];
        }

        /// Await all results, allocating a slice for them.
        /// Caller owns the returned slice.
        pub fn awaitAll(self: *Self, io: Io) ![]Clean {
            var results = try self.allocator.alloc(Clean, self.futures.len);
            errdefer self.allocator.free(results);

            for (self.futures, 0..) |*f, i| {
                const r = f.await(io);
                results[i] = if (Result == Clean) r else try r;
            }

            return results;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.futures);
        }
    };
}

/// Stack-allocated batch of futures. Zero heap allocations.
/// Use when the batch size is known at comptime.
pub fn InlineBatchFuture(comptime Result: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Clean = UnwrapErrorUnion(Result);

        futures: [capacity]Io.Future(Result),
        len: usize,

        /// Await all results into a caller-provided buffer. Zero allocations.
        pub fn awaitAllBuf(self: *Self, io: Io, results: []Clean) []Clean {
            const len = @min(self.len, results.len);
            for (self.futures[0..len], 0..) |*f, i| {
                const r = f.await(io);
                results[i] = if (Result == Clean) r else r catch unreachable;
            }
            return results[0..len];
        }

        /// Await all results into an inline array. Zero allocations.
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

fn UnwrapErrorUnion(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}
