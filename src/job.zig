const std = @import("std");
const AtomicCounter = @import("counter.zig").AtomicCounter;

pub const Priority = enum(u2) {
    high = 0,
    normal = 1,
    low = 2,
};

pub const JobDescriptor = struct {
    func: *const fn (*anyopaque) void,
    data: *anyopaque,
    priority: Priority,
    counter: *AtomicCounter,
    parent: ?*AtomicCounter,
};
