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

test "validateJobType accepts valid job" {
    validateJobType(ValidJob);
}

test "validateJobType accepts job returning error union" {
    validateJobType(ErrorJob);
}

test "JobResult extracts return type" {
    try testing.expect(JobResult(ValidJob) == i32);
    try testing.expect(JobResult(ErrorJob) == @TypeOf(@as(ErrorJob, undefined).execute()));
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
