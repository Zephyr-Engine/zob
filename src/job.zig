const std = @import("std");

/// Validates at comptime that T is a valid zob job type.
///
/// Requirements:
/// - T must be a struct
/// - T must have a public `execute` declaration
/// - `execute` must be a function
/// - `execute` must take exactly one parameter (self)
pub fn validateJobType(comptime T: type) void {
    const type_info = @typeInfo(T);

    if (type_info != .@"struct") {
        @compileError("zob job type must be a struct, got: " ++ @typeName(T));
    }

    if (!@hasDecl(T, "execute")) {
        @compileError("zob job type `" ++ @typeName(T) ++ "` must have a public `execute` function");
    }

    const execute_info = @typeInfo(@TypeOf(T.execute));

    if (execute_info != .@"fn") {
        @compileError("`execute` on `" ++ @typeName(T) ++ "` must be a function");
    }

    const func = execute_info.@"fn";

    if (func.params.len != 1) {
        @compileError("`execute` on `" ++ @typeName(T) ++ "` must take exactly one parameter (self), got " ++ std.fmt.comptimePrint("{d}", .{func.params.len}));
    }
}

pub fn JobResult(comptime T: type) type {
    validateJobType(T);
    const func = @typeInfo(@TypeOf(T.execute)).@"fn";
    return func.return_type.?;
}

pub fn makeRunner(comptime T: type) fn (T) JobResult(T) {
    return struct {
        fn run(data: T) JobResult(T) {
            return data.execute();
        }
    }.run;
}

const testing = std.testing;

const ValidJob = struct {
    value: i32,

    pub fn execute(self: @This()) i32 {
        return self.value * 2;
    }
};

const ErrorJob = struct {
    should_fail: bool,

    pub fn execute(self: @This()) !i32 {
        if (self.should_fail) return error.JobFailed;
        return 42;
    }
};

const VoidJob = struct {
    pub fn execute(self: @This()) void {
        _ = self;
    }
};

const U64Job = struct {
    x: u64,

    pub fn execute(self: @This()) u64 {
        return self.x *% 6364136223846793005;
    }
};

const MultiErrorJob = struct {
    code: u8,

    pub fn execute(self: @This()) error{ Alpha, Beta, Gamma }!u32 {
        return switch (self.code) {
            0 => error.Alpha,
            1 => error.Beta,
            2 => error.Gamma,
            else => self.code * 10,
        };
    }
};

test "validateJobType accepts valid job" {
    validateJobType(ValidJob);
}

test "validateJobType accepts job returning error union" {
    validateJobType(ErrorJob);
}

test "validateJobType accepts void return" {
    validateJobType(VoidJob);
}

test "validateJobType accepts u64 return" {
    validateJobType(U64Job);
}

test "validateJobType accepts multi-error return" {
    validateJobType(MultiErrorJob);
}

test "JobResult extracts return type" {
    try testing.expect(JobResult(ValidJob) == i32);
    try testing.expect(JobResult(ErrorJob) == @TypeOf(@as(ErrorJob, undefined).execute()));
    try testing.expect(JobResult(VoidJob) == void);
    try testing.expect(JobResult(U64Job) == u64);
}

test "makeRunner produces callable function" {
    const runner = makeRunner(ValidJob);
    const result = runner(.{ .value = 21 });
    try testing.expectEqual(@as(i32, 42), result);
}

test "makeRunner handles error union" {
    const runner = makeRunner(ErrorJob);
    const ok = try runner(.{ .should_fail = false });
    try testing.expectEqual(@as(i32, 42), ok);
    const err = runner(.{ .should_fail = true });
    try testing.expectError(error.JobFailed, err);
}

test "makeRunner handles void return" {
    const runner = makeRunner(VoidJob);
    runner(.{});
}

test "makeRunner handles u64" {
    const runner = makeRunner(U64Job);
    const result = runner(.{ .x = 1 });
    try testing.expectEqual(@as(u64, 6364136223846793005), result);
}

test "makeRunner handles multi-error job" {
    const runner = makeRunner(MultiErrorJob);
    try testing.expectError(error.Alpha, runner(.{ .code = 0 }));
    try testing.expectError(error.Beta, runner(.{ .code = 1 }));
    try testing.expectError(error.Gamma, runner(.{ .code = 2 }));
    const ok = try runner(.{ .code = 5 });
    try testing.expectEqual(@as(u32, 50), ok);
}
