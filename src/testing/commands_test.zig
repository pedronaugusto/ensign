//! Subcommands nested to any depth, aliases, global options and the flags
//! the parser answers itself.
const std = @import("std");
const ensign = @import("../ensign.zig");
const support = @import("support.zig");

const Leaf = struct {
    deep: bool = false,
    item: []const u8 = "",
    pub const spec: ensign.Spec(@This()) = .{ .about = "The bottom", .options = .{ .item = .{ .positional = true } } };
};

const Third = struct {
    third: u8 = 0,
    command: union(enum) { leaf: Leaf },
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .third = .{ .global = true, .short = 't' } } };
};

const Second = struct {
    local: bool = false,
    tags: []const []const u8 = &.{},
    command: union(enum) { third: Third, nothing },
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .tags = .{ .global = true } }, .commands = .{ .nothing = .{ .help = "Does nothing" } } };
};

const Root = struct {
    verbose: u8 = 0,
    color: enum { auto, never } = .auto,
    quiet: bool = false,
    command: ?union(enum) { second: Second, other_thing: struct { x: bool = false } } = null,
    pub const spec: ensign.Spec(@This()) = .{
        .name = "root",
        .version = "2.0.0",
        .options = .{
            .verbose = .{ .short = 'v', .count = true, .global = true },
            .color = .{ .global = true },
        },
        .commands = .{ .second = .{ .aliases = &.{ "2nd", "s" } } },
    };
};

test "four levels, each with its own options" {
    const v = try support.parsed(Root, &.{ "-v", "second", "--local", "third", "-t", "4", "leaf", "--deep", "x" });
    const second = v.command.?.second;
    try std.testing.expect(second.local);
    const third = second.command.third;
    try std.testing.expectEqual(@as(u8, 4), third.third);
    const leaf = third.command.leaf;
    try std.testing.expect(leaf.deep);
    try std.testing.expectEqualStrings("x", leaf.item);
}

test "a global option is accepted below and kept above" {
    const v = try support.parsed(Root, &.{ "s", "third", "leaf", "-vv", "--color=never", "--tags=a", "-t3", "--tags", "b", "-v" });
    defer ensign.free(Root, std.testing.allocator, &v);
    try std.testing.expectEqual(@as(u8, 3), v.verbose);
    try std.testing.expectEqual(.never, v.color);
    const second = v.command.?.second;
    try std.testing.expectEqual(@as(usize, 2), second.tags.len);
    try std.testing.expectEqual(@as(u8, 3), second.command.third.third);
}

test "an option that is not global stays at its command" {
    try support.fails(Root, &.{ "second", "--quiet" }, error.UnknownOption, "root second: unknown option '--quiet'");
    try support.fails(Root, &.{ "second", "third", "--local" }, error.UnknownOption, "root second third: unknown option '--local'");
    const v = try support.parsed(Root, &.{ "--quiet", "second", "nothing" });
    try std.testing.expect(v.quiet);
    try std.testing.expectEqual(.nothing, v.command.?.second.command);
}

test "aliases select the same command" {
    for ([_][]const u8{ "second", "2nd", "s" }) |name| {
        const v = try support.parsed(Root, &.{ name, "nothing" });
        try std.testing.expect(v.command.? == .second);
    }
    const v = try support.parsed(Root, &.{"other-thing"});
    try std.testing.expect(v.command.? == .other_thing);
}

test "an optional command may be left out, a required one may not" {
    const v = try support.parsed(Root, &.{"-v"});
    try std.testing.expectEqual(null, v.command);
    try support.fails(Root, &.{"second"}, error.MissingCommand, "root second: missing command: expected one of third, nothing");
    try support.fails(Root, &.{ "second", "third" }, error.MissingCommand, "root second third: missing command: expected one of leaf");
}

test "unknown commands, with the nearest named" {
    try support.fails(Root, &.{"secnod"}, error.UnknownCommand, "root: unknown command 'secnod'; did you mean 'second'?");
    try support.fails(Root, &.{ "second", "thrid" }, error.UnknownCommand, "root second: unknown command 'thrid'; did you mean 'third'?");
    try support.fails(Root, &.{"zzz"}, error.UnknownCommand, "root: unknown command 'zzz'");
}

test "help is the help of the command it follows" {
    var buffer: [4096]u8 = undefined;
    const root = try support.helpPage(Root, &.{"--help"}, 80, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, root, "Usage: root [options] [command]\n"));
    const leaf = try support.helpPage(Root, &.{ "second", "third", "leaf", "-h" }, 80, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, leaf, "The bottom\n\nUsage: root second third leaf [options] [ITEM]\n"));
    const nothing = try support.helpPage(Root, &.{ "second", "nothing", "--help" }, 80, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, nothing, "Does nothing\n\nUsage: root second nothing [options]\n"));
    // Help comes before what is still missing.
    _ = try support.helpPage(Root, &.{ "second", "-h" }, 80, &buffer);
}

test "the version is answered where it is declared" {
    for ([_][]const []const u8{ &.{"--version"}, &.{ "-v", "-V" } }) |args| {
        const outcome = try ensign.parse(Root, std.testing.allocator, args, .{});
        var buffer: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try outcome.version.write(&w);
        try std.testing.expectEqualStrings("root 2.0.0\n", w.buffered());
    }
    try support.fails(Root, &.{ "second", "--version" }, error.UnknownOption, "root second: unknown option '--version'");
    try support.fails(Root, &.{"--help=x"}, error.UnexpectedValue, "root: '--help' takes no value, but was given 'x'");
}

test "a program can take --help and --version for its own" {
    const Own = struct {
        help: bool = false,
        version: ?[]const u8 = null,
        pub const spec: ensign.Spec(@This()) = .{ .version = "1", .help = null, .version_flag = null, .options = .{ .help = .{ .short = 'h' } } };
    };
    const v = try support.parsed(Own, &.{ "-h", "--version=3" });
    try std.testing.expect(v.help);
    try std.testing.expectEqualStrings("3", v.version.?);
    const Renamed = struct {
        x: bool = false,
        pub const spec: ensign.Spec(@This()) = .{ .help = .{ .long = "usage", .short = '?' } };
    };
    var buffer: [512]u8 = undefined;
    _ = try support.helpPage(Renamed, &.{"-?"}, 80, &buffer);
    _ = try support.helpPage(Renamed, &.{"--usage"}, 80, &buffer);
    try support.fails(Renamed, &.{"--help"}, error.UnknownOption, "program: unknown option '--help'");
}
