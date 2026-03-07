const std = @import("std");

pub const AtomicCounter = struct {
    value: std.atomic.Value(u32),

    pub fn init(val: u32) AtomicCounter {
        return .{
            .value = std.atomic.Value(u32).init(val),
        };
    }

    pub fn decrement(self: *AtomicCounter) u32 {
        return self.value.fetchSub(1, .release);
    }

    pub fn get(self: *AtomicCounter) u32 {
        return self.value.load(.acquire);
    }

    pub fn isComplete(self: *AtomicCounter) bool {
        return self.get() == 0;
    }
};
