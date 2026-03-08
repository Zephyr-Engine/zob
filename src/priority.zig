pub const Priority = enum(u2) {
    /// Frame-critical work: physics, animation, visibility
    high = 0,
    /// Standard work: AI, scripting, audio
    normal = 1,
    /// Deferrable background work: streaming, compression
    low = 2,
};

const testing = @import("std").testing;

test "priority ordering values" {
    try testing.expect(@intFromEnum(Priority.high) < @intFromEnum(Priority.normal));
    try testing.expect(@intFromEnum(Priority.normal) < @intFromEnum(Priority.low));
}

test "priority enum round-trips" {
    const values = [_]Priority{ .high, .normal, .low };
    for (values) |p| {
        const as_int = @intFromEnum(p);
        const back: Priority = @enumFromInt(as_int);
        try testing.expectEqual(p, back);
    }
}
