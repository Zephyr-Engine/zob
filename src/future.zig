const std = @import("std");
const Io = std.Io;

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
                results[i] = if (Result == Clean) r else try r;
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

fn UnwrapErrorUnion(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}
