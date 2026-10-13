//! Typed values: integers, floats, enums, text, paths, flags, counts,
//! optionals, lists, defaults and what is required.
const std = @import("std");
const ensign = @import("../ensign.zig");
const support = @import("support.zig");

const Mode = enum { fast, safe_mode, small };

const T = struct {
    small: u8 = 0,
    signed: i64 = 0,
    wide: u128 = 0,
    ratio: f64 = 1.5,
    mode: Mode = .fast,
    name: []const u8 = "anonymous",
    path: ?[]const u8 = null,
    color: ?bool = null,
    loud: bool = true,
    verbose: u2 = 0,
    tags: []const []const u8 = &.{ "a", "b" },
    sizes: []const u16 = &.{},
    modes: []const Mode = &.{},

    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .path = .{ .hint = .file },
        .verbose = .{ .short = 'v', .count = true },
        .sizes = .{ .delimiter = ',' },
        .modes = .{ .short = 'm' },
    } };
};

test "defaults stand when nothing is given" {
    const v = try support.parsed(T, &.{});
    defer ensign.free(T, std.testing.allocator, &v);
    try std.testing.expectEqual(@as(f64, 1.5), v.ratio);
    try std.testing.expectEqualStrings("anonymous", v.name);
    try std.testing.expectEqual(@as(?bool, null), v.color);
    try std.testing.expect(v.loud);
    try std.testing.expectEqual(@as(usize, 2), v.tags.len);
}

test "integers in every base, with bounds" {
    const v = try support.parsed(T, &.{ "--small=0xff", "--signed=-0b101", "--wide=340282366920938463463374607431768211455", "--signed", "1_000" });
    try std.testing.expectEqual(@as(u8, 255), v.small);
    try std.testing.expectEqual(@as(i64, 1000), v.signed);
    try std.testing.expectEqual(std.math.maxInt(u128), v.wide);
    try support.fails(T, &.{"--small=256"}, error.InvalidValue, "program: invalid value '256' for '--small': expected an integer from 0 to 255");
    try support.fails(T, &.{"--small=-1"}, error.InvalidValue, "program: invalid value '-1' for '--small': expected an integer from 0 to 255");
    try support.fails(T, &.{"--signed=1e3"}, error.InvalidValue, "program: invalid value '1e3' for '--signed': expected an integer from -9223372036854775808 to 9223372036854775807");
}

test "floats" {
    var v = try support.parsed(T, &.{"--ratio=-2.5e-3"});
    try std.testing.expectEqual(@as(f64, -2.5e-3), v.ratio);
    v = try support.parsed(T, &.{"--ratio=inf"});
    try std.testing.expect(std.math.isInf(v.ratio));
    try support.fails(T, &.{"--ratio=half"}, error.InvalidValue, "program: invalid value 'half' for '--ratio': expected a number");
}

test "enums by tag, with - for _" {
    var v = try support.parsed(T, &.{"--mode=safe-mode"});
    try std.testing.expectEqual(Mode.safe_mode, v.mode);
    v = try support.parsed(T, &.{"--mode=safe_mode"});
    try std.testing.expectEqual(Mode.safe_mode, v.mode);
    try support.fails(T, &.{"--mode=smal"}, error.InvalidValue, "program: invalid value 'smal' for '--mode': expected one of fast, safe-mode, small; did you mean 'small'?");
    try support.fails(T, &.{"--mode=Fast"}, error.InvalidValue, "program: invalid value 'Fast' for '--mode': expected one of fast, safe-mode, small; did you mean 'fast'?");
}

test "text and paths are bytes, whatever they hold" {
    const bytes = "\xff\xfe\xed\xa0\x80 é";
    const v = try support.parsed(T, &.{ "--name", bytes, "--path=\xc3" });
    try std.testing.expectEqualStrings(bytes, v.name);
    try std.testing.expectEqualStrings("\xc3", v.path.?);
}

test "an optional flag tells absent from false" {
    var v = try support.parsed(T, &.{"--color"});
    try std.testing.expectEqual(@as(?bool, true), v.color);
    v = try support.parsed(T, &.{"--no-color"});
    try std.testing.expectEqual(@as(?bool, false), v.color);
    v = try support.parsed(T, &.{"--no-loud"});
    try std.testing.expect(!v.loud);
}

test "a count saturates at its type's maximum" {
    const v = try support.parsed(T, &.{ "-vvvvv", "--verbose" });
    try std.testing.expectEqual(@as(u2, 3), v.verbose);
}

test "lists gather every occurrence and replace their default" {
    const v = try support.parsed(T, &.{ "--tags=x", "--sizes=1,2", "--tags", "y", "--sizes=3", "-mfast", "-m", "small" });
    defer ensign.free(T, std.testing.allocator, &v);
    try std.testing.expectEqual(@as(usize, 2), v.tags.len);
    try std.testing.expectEqualStrings("x", v.tags[0]);
    try std.testing.expectEqualStrings("y", v.tags[1]);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, v.sizes);
    try std.testing.expectEqualSlices(Mode, &.{ .fast, .small }, v.modes);
    try support.fails(T, &.{"--sizes=1,,2"}, error.InvalidValue, "program: invalid value '' for '--sizes': expected an integer from 0 to 65535");
}

const Required = struct {
    target: []const u8,
    files: []const []const u8,
    first: []const u8,
    second: ?u8 = null,
    rest: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .target = .{ .value_name = "TRIPLE", .env = "TARGET" },
        .files = .{ .short = 'f' },
        .first = .{ .positional = true },
        .second = .{ .positional = true },
        .rest = .{ .positional = true },
    } };
};

test "what is required" {
    const v = try support.parsed(Required, &.{ "one", "--target=x", "-f", "a", "2", "r1", "r2" });
    defer ensign.free(Required, std.testing.allocator, &v);
    try std.testing.expectEqualStrings("one", v.first);
    try std.testing.expectEqual(@as(?u8, 2), v.second);
    try std.testing.expectEqual(@as(usize, 2), v.rest.len);
    try support.fails(Required, &.{ "one", "-f", "a" }, error.MissingOption, "program: missing option '--target <TRIPLE>' (or set TARGET)");
    try support.fails(Required, &.{ "one", "--target=x" }, error.MissingOption, "program: missing option '--files <FILES>'");
    try support.fails(Required, &.{ "--target=x", "-fa" }, error.MissingArgument, "program: missing argument <FIRST>");
    try support.fails(Required, &.{ "one", "x", "--target=x", "-fa" }, error.InvalidValue, "program: invalid value 'x' for '[SECOND]': expected an integer from 0 to 255");
}

test "past the last positional" {
    const One = struct {
        only: ?[]const u8 = null,
        pub const spec: ensign.Spec(@This()) = .{ .options = .{ .only = .{ .positional = true } } };
    };
    try support.fails(One, &.{ "a", "b" }, error.UnexpectedArgument, "program: unexpected argument 'b'");
    try support.fails(struct { x: bool = false }, &.{"stray"}, error.UnexpectedArgument, "program: unexpected argument 'stray'");
}

test "render writes a value back, and refuses what no command line gives" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try ensign.render(T, a, .{ .small = 7, .mode = .safe_mode, .color = false, .loud = false, .verbose = 2, .tags = &.{"x"}, .sizes = &.{ 1, 2 } });
    const want = [_][]const u8{ "--small=7", "--mode=safe-mode", "--no-color", "--no-loud", "--verbose", "--verbose", "--tags=x", "--sizes=1", "--sizes=2" };
    try std.testing.expectEqual(want.len, args.len);
    for (want, args) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expectError(error.Unrepresentable, ensign.render(T, a, .{ .tags = &.{} }));
    const Counted = struct {
        level: u8 = 2,
        strict: bool = true,
        pub const spec: ensign.Spec(@This()) = .{ .options = .{ .level = .{ .count = true }, .strict = .{ .negatable = false } } };
    };
    try std.testing.expectError(error.Unrepresentable, ensign.render(Counted, a, .{ .level = 1 }));
    try std.testing.expectError(error.Unrepresentable, ensign.render(Counted, a, .{ .strict = false }));
    const Path = struct {
        path: ?[]const u8 = "here",
    };
    try std.testing.expectError(error.Unrepresentable, ensign.render(Path, a, .{ .path = null }));
}
