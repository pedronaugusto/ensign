//! A program that wraps another: arguments passed on as given, and commands
//! found at run time.
const std = @import("std");
const ensign = @import("../ensign.zig");
const support = @import("support.zig");

const Build = struct {
    verbose: bool = false,
    file: []const u8 = "",
    args: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Build with the arguments passed on",
        .options = .{
            .verbose = .{ .short = 'v' },
            .file = .{ .positional = true },
            .args = .{ .positional = true, .raw = true, .help = "Passed to the build as given" },
        },
    };
};

const Tool = struct {
    jobs: u8 = 1,
    command: union(enum) {
        build: Build,
        list,
        step: ensign.External,
    },
    pub const spec: ensign.Spec(@This()) = .{
        .name = "tool",
        .options = .{ .jobs = .{ .short = 'j', .global = true } },
        .commands = .{ .step = .{ .help = "Run a step of the build" } },
    };
};

fn expectArgs(expected: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "raw arguments start at the first argument the command does not read" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { given: []const []const u8, file: []const u8, verbose: bool, rest: []const []const u8 }{
        .{ .given = &.{ "build", "f", "-Doptimize=ReleaseSafe", "--verbose" }, .file = "f", .verbose = false, .rest = &.{ "-Doptimize=ReleaseSafe", "--verbose" } },
        .{ .given = &.{ "build", "-v", "f", "--summary", "all" }, .file = "f", .verbose = true, .rest = &.{ "--summary", "all" } },
        .{ .given = &.{ "build", "f", "x", "--", "-v" }, .file = "f", .verbose = false, .rest = &.{ "x", "--", "-v" } },
        .{ .given = &.{ "build", "f", "--", "-v" }, .file = "f", .verbose = false, .rest = &.{"-v"} },
        .{ .given = &.{ "build", "--", "-f", "-v" }, .file = "-f", .verbose = false, .rest = &.{"-v"} },
        .{ .given = &.{ "build", "f" }, .file = "f", .verbose = false, .rest = &.{} },
    };
    for (cases) |case| {
        const v = try support.parsed(Tool, case.given);
        defer ensign.free(Tool, gpa, &v);
        const b = v.command.build;
        try std.testing.expectEqualStrings(case.file, b.file);
        try std.testing.expectEqual(case.verbose, b.verbose);
        try expectArgs(case.rest, b.args);
    }
}

test "an option the command reads before its positionals are taken is still an error" {
    try support.fails(Tool, &.{ "build", "--verbos" }, error.UnknownOption, "tool build: unknown option '--verbos'; did you mean '--verbose'?");
}

test "a global option above is read until the raw arguments start, and passed on after" {
    const gpa = std.testing.allocator;
    const v = try support.parsed(Tool, &.{ "build", "-j", "4", "f", "x", "-j", "2" });
    defer ensign.free(Tool, gpa, &v);
    try std.testing.expectEqual(4, v.jobs);
    try expectArgs(&.{ "x", "-j", "2" }, v.command.build.args);
}

test "an unknown command is the external one, with every argument after it as given" {
    const gpa = std.testing.allocator;
    {
        const v = try support.parsed(Tool, &.{ "-j", "3", "conformance", "--seed", "7", "--", "-x" });
        defer ensign.free(Tool, gpa, &v);
        try std.testing.expectEqual(3, v.jobs);
        try std.testing.expectEqualStrings("conformance", v.command.step.name);
        try expectArgs(&.{ "--seed", "7", "--", "-x" }, v.command.step.args);
    }
    {
        const v = try support.parsed(Tool, &.{"bench"});
        defer ensign.free(Tool, gpa, &v);
        try std.testing.expectEqualStrings("bench", v.command.step.name);
        try std.testing.expectEqual(0, v.command.step.args.len);
    }
    // A known name is never the external command.
    const v = try support.parsed(Tool, &.{"list"});
    defer ensign.free(Tool, gpa, &v);
    try std.testing.expect(v.command == .list);
}

test "help shows the raw arguments and the external command" {
    var buffer: [4096]u8 = undefined;
    const page = try support.helpPage(Tool, &.{"--help"}, 80, &buffer);
    try std.testing.expect(std.mem.find(u8, page, "<step>") != null);
    try std.testing.expect(std.mem.find(u8, page, "Run a step of the build") != null);
    const build_page = try support.helpPage(Tool, &.{ "build", "--help" }, 80, &buffer);
    try std.testing.expect(std.mem.find(u8, build_page, "Passed to the build as given") != null);
}

test "completions offer no external command by its placeholder" {
    var buffer: [64 * 1024]u8 = undefined;
    inline for (.{ ensign.Shell.bash, ensign.Shell.zsh, ensign.Shell.fish, ensign.Shell.powershell }) |shell| {
        var w: std.Io.Writer = .fixed(&buffer);
        try ensign.writeCompletion(Tool, shell, &w, "tool");
        try std.testing.expect(std.mem.find(u8, w.buffered(), "<step>") == null);
        try std.testing.expect(std.mem.find(u8, w.buffered(), "build") != null);
    }
}

test "render writes raw arguments and an external command so they parse back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gpa = std.testing.allocator;
    const values = [_]Tool{
        .{ .command = .{ .build = .{ .file = "f", .args = &.{ "-v", "--", "x" } } } },
        .{ .command = .{ .build = .{ .file = "-f", .args = &.{"y"} } } },
        .{ .jobs = 2, .command = .{ .step = .{ .name = "bench", .args = &.{ "--filter", "a", "--" } } } },
    };
    for (values) |value| {
        const args = try ensign.render(Tool, a, value);
        const back = try support.parsed(Tool, args);
        defer ensign.free(Tool, gpa, &back);
        try std.testing.expectEqual(value.jobs, back.jobs);
        switch (value.command) {
            .build => |b| {
                try std.testing.expectEqualStrings(b.file, back.command.build.file);
                try expectArgs(b.args, back.command.build.args);
            },
            .step => |s| {
                try std.testing.expectEqualStrings(s.name, back.command.step.name);
                try expectArgs(s.args, back.command.step.args);
            },
            .list => {},
        }
    }
    // A name another command has, or one that reads as an option, cannot be written.
    try std.testing.expectError(error.Unrepresentable, ensign.render(Tool, a, .{ .command = .{ .step = .{ .name = "list" } } }));
    try std.testing.expectError(error.Unrepresentable, ensign.render(Tool, a, .{ .command = .{ .step = .{ .name = "-x" } } }));
}
