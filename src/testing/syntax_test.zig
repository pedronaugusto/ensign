//! How arguments are spelled: long and short options, attached and separate
//! values, clusters, `--` and `-`.
const std = @import("std");
const ensign = @import("../ensign.zig");
const support = @import("support.zig");

const T = struct {
    all: bool = false,
    brief: bool = false,
    count: u8 = 0,
    output: ?[]const u8 = null,
    level: i32 = 0,
    inputs: []const []const u8 = &.{},

    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .all = .{ .short = 'a' },
        .brief = .{ .short = 'b' },
        .count = .{ .short = 'c', .count = true },
        .output = .{ .short = 'o' },
        .level = .{ .short = 'l' },
        .inputs = .{ .positional = true },
    } };
};

fn expectOutput(args: []const []const u8, want: ?[]const u8) !void {
    const v = try support.parsed(T, args);
    defer ensign.free(T, std.testing.allocator, &v);
    if (want) |w| try std.testing.expectEqualStrings(w, v.output.?) else try std.testing.expectEqual(@as(?[]const u8, null), v.output);
}

test "a value attached or separate, long or short" {
    try expectOutput(&.{"--output=x"}, "x");
    try expectOutput(&.{ "--output", "x" }, "x");
    try expectOutput(&.{ "-o", "x" }, "x");
    try expectOutput(&.{"-ox"}, "x");
    try expectOutput(&.{"-o=x"}, "x");
    try expectOutput(&.{"--output="}, "");
    try expectOutput(&.{"--output=a=b"}, "a=b");
}

test "a value is taken as it is, dashes and all" {
    try expectOutput(&.{ "-o", "--" }, "--");
    try expectOutput(&.{ "--output", "-a" }, "-a");
    try expectOutput(&.{ "-o", "" }, "");
    const v = try support.parsed(T, &.{ "--level", "-5", "-l-6" });
    try std.testing.expectEqual(@as(i32, -6), v.level);
}

test "a later value replaces an earlier one" {
    try expectOutput(&.{ "-o", "a", "--output=b" }, "b");
}

test "short clusters" {
    const v = try support.parsed(T, &.{ "-abc", "-cc" });
    try std.testing.expect(v.all and v.brief);
    try std.testing.expectEqual(@as(u8, 3), v.count);
    try expectOutput(&.{ "-abo", "x" }, "x");
    try expectOutput(&.{"-abox"}, "x");
    try expectOutput(&.{"-cco=y"}, "y");
}

test "-- ends options and - is a positional" {
    const v = try support.parsed(T, &.{ "-", "--", "-a", "--output=x", "--" });
    defer ensign.free(T, std.testing.allocator, &v);
    try std.testing.expect(!v.all);
    try std.testing.expectEqual(@as(?[]const u8, null), v.output);
    try std.testing.expectEqual(@as(usize, 4), v.inputs.len);
    for ([_][]const u8{ "-", "-a", "--output=x", "--" }, v.inputs) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a negative number is a positional where no short option is a digit" {
    const v = try support.parsed(T, &.{ "-5", "-.5", "x" });
    defer ensign.free(T, std.testing.allocator, &v);
    try std.testing.expectEqualStrings("-5", v.inputs[0]);
    try std.testing.expectEqualStrings("-.5", v.inputs[1]);
    const Digits = struct {
        five: bool = false,
        rest: []const []const u8 = &.{},
        pub const spec: ensign.Spec(@This()) = .{ .options = .{ .five = .{ .short = '5' }, .rest = .{ .positional = true } } };
    };
    const d = try support.parsed(Digits, &.{"-5"});
    try std.testing.expect(d.five);
}

test "empty arguments are positionals" {
    const v = try support.parsed(T, &.{ "", "" });
    defer ensign.free(T, std.testing.allocator, &v);
    try std.testing.expectEqual(@as(usize, 2), v.inputs.len);
}

test "flags take true or false after =, and --no- negates" {
    var v = try support.parsed(T, &.{ "--all=yes", "--brief=1" });
    try std.testing.expect(v.all and v.brief);
    v = try support.parsed(T, &.{ "--all", "--no-all", "-b", "--brief=off" });
    try std.testing.expect(!v.all and !v.brief);
    try support.fails(T, &.{"--all=maybe"}, error.InvalidValue, "program: invalid value 'maybe' for '--all': expected true or false");
    try support.fails(T, &.{"--no-all=1"}, error.UnexpectedValue, "program: '--no-all' takes no value, but was given '1'");
    try support.fails(T, &.{"--count=2"}, error.UnexpectedValue, "program: '--count' takes no value, but was given '2'");
}

test "options that are not there" {
    try support.fails(T, &.{"-x"}, error.UnknownOption, "program: unknown option '-x'");
    try support.fails(T, &.{"-abx"}, error.UnknownOption, "program: unknown option '-x'");
    try support.fails(T, &.{"-a\xff"}, error.UnknownOption, "program: unknown option '-\\xff'");
    try support.fails(T, &.{"---all"}, error.UnknownOption, "program: unknown option '---all'; did you mean '--all'?");
    try support.fails(T, &.{"--no-count"}, error.UnknownOption, "program: unknown option '--no-count'; did you mean '--count'?");
    try support.fails(T, &.{"--outptu=x"}, error.UnknownOption, "program: unknown option '--outptu'; did you mean '--output'?");
}

test "a value that never comes" {
    try support.fails(T, &.{"--output"}, error.MissingValue, "program: '--output' needs a value: text");
    try support.fails(T, &.{"-ao"}, error.MissingValue, "program: '--output' needs a value: text");
    try support.fails(T, &.{"-l"}, error.MissingValue, "program: '--level' needs a value: an integer from -2147483648 to 2147483647");
}
