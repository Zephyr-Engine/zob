const std = @import("std");
const Io = std.Io;

pub fn State(comptime Result: type) type {
    return struct {
        allocator: std.mem.Allocator,
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        done: bool = false,
        result: Result = undefined,

        pub fn create(allocator: std.mem.Allocator) !*@This() {
            const state = try allocator.create(@This());
            state.* = .{ .allocator = allocator };
            return state;
        }

        pub fn resolve(self: *@This(), io: Io, result: Result) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.result = result;
            self.done = true;
            self.cond.broadcast(io);
        }

        fn wait(self: *@This(), io: Io) Result {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (!self.done) {
                self.cond.waitUncancelable(io, &self.mutex);
            }
            return self.result;
        }
    };
}

pub fn Future(comptime Result: type) type {
    return struct {
        const Self = @This();

        inner: ?Io.Future(Result) = null,
        state: ?*State(Result) = null,
        cached: ?Result = null,

        pub fn init(state: *State(Result)) Self {
            return .{ .state = state };
        }

        pub fn fromIoFuture(inner: Io.Future(Result)) Self {
            return .{ .inner = inner };
        }

        pub fn await(self: *Self, io: Io) Result {
            if (self.cached) |result| {
                return result;
            }

            const result = if (self.inner) |*inner|
                inner.await(io)
            else blk: {
                const state = self.state orelse unreachable;
                const state_result = state.wait(io);
                state.allocator.destroy(state);
                self.state = null;
                break :blk state_result;
            };
            self.inner = null;
            self.cached = result;
            return result;
        }

        pub fn cancel(self: *Self, io: Io) Result {
            if (self.cached) |result| {
                return result;
            }

            if (self.inner) |*inner| {
                const result = inner.cancel(io);
                self.inner = null;
                self.cached = result;
                return result;
            }
            return self.await(io);
        }
    };
}

pub fn BatchFuture(comptime Result: type) type {
    return struct {
        const Self = @This();
        const Clean = UnwrapErrorUnion(Result);

        futures: []Future(Result),
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
                        // Await remaining futures so their completion state is released.
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

        futures: [capacity]Future(Result),
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
