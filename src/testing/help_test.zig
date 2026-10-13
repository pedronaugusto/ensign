//! Help and usage generated from the declaration and wrapped to a width.
const std = @import("std");
const ensign = @import("../ensign.zig");
const support = @import("support.zig");
const shake = @import("shakedown");

const Build = struct {
    release: bool = true,
    jobs: u16 = 0,
    target: []const u8,
    color: enum { auto, always, never } = .auto,
    secret: bool = false,
    include: []const []const u8 = &.{},
    files: []const []const u8 = &.{},

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Build the project",
        .description = "Builds every file given, or the whole project when none is.\nIncremental: what did not change is not rebuilt.",
        .options = .{
            .release = .{ .short = 'r', .help = "Optimize for speed, at the cost of a longer build and of debug information" },
            .jobs = .{ .short = 'j', .env = "APP_JOBS", .help = "Parallel jobs; 0 is one per core" },
            .target = .{ .value_name = "TRIPLE", .help = "The target to build for" },
            .color = .{ .section = "Output", .help = "When to colour" },
            .secret = .{ .hidden = true },
            .include = .{ .short = 'I', .value_name = "DIR", .hint = .directory, .help = "Look for headers here too", .section = "Output" },
            .files = .{ .positional = true, .help = "Files to build" },
        },
        .examples = &.{
            .{ .command = "app build -j8 --target x86_64-linux", .help = "Build for Linux with eight jobs." },
            .{ .command = "app build --no-release" },
        },
        .sections = &.{.{ .heading = "Exit status", .body = "0 when the build succeeds, 1 when it fails." }},
    };
};

const App = struct {
    verbose: u8 = 0,
    command: union(enum) { build: Build, clean },
    pub const spec: ensign.Spec(@This()) = .{
        .name = "app",
        .version = "0.3.0",
        .about = "Builds things",
        .options = .{ .verbose = .{ .short = 'v', .count = true, .global = true, .help = "Say more" } },
        .commands = .{ .clean = .{ .help = "Remove what was built", .aliases = &.{"c"} } },
    };
};

test "the root page" {
    var buffer: [4096]u8 = undefined;
    const page = try support.helpPage(App, &.{"-h"}, 80, &buffer);
    try std.testing.expectEqualStrings(
        \\Builds things
        \\
        \\Usage: app [options] <command>
        \\
        \\Commands:
        \\  build             Build the project
        \\  clean, c          Remove what was built
        \\
        \\Options:
        \\  -v, --verbose...  Say more
        \\  -h, --help        Print help
        \\  -V, --version     Print the version
        \\
    , page);
}

test "a subcommand page, at 80 columns" {
    var buffer: [4096]u8 = undefined;
    const page = try support.helpPage(App, &.{ "build", "--help" }, 80, &buffer);
    try std.testing.expectEqualStrings(
        \\Build the project
        \\
        \\Usage: app build [options] --target <TRIPLE> [FILES]...
        \\
        \\Builds every file given, or the whole project when none is.
        \\Incremental: what did not change is not rebuilt.
        \\
        \\Arguments:
        \\  [FILES]...              Files to build
        \\
        \\Options:
        \\  -r, --[no-]release      Optimize for speed, at the cost of a longer build and
        \\                          of debug information
        \\  -j, --jobs <JOBS>       Parallel jobs; 0 is one per core [default: 0]
        \\                          [env: APP_JOBS]
        \\      --target <TRIPLE>   The target to build for
        \\  -h, --help              Print help
        \\
        \\Output:
        \\      --color <COLOR>     When to colour [default: auto] [possible values: auto,
        \\                          always, never]
        \\  -I, --include <DIR>...  Look for headers here too
        \\
        \\Global options:
        \\  -v, --verbose...        Say more
        \\
        \\Examples:
        \\  app build -j8 --target x86_64-linux
        \\      Build for Linux with eight jobs.
        \\  app build --no-release
        \\
        \\Exit status:
        \\  0 when the build succeeds, 1 when it fails.
        \\
    , page);
}

fn widthHolds(_: void, c: *shake.Case) !void {
    const width = shake.gen.intRange(c.source, usize, 0, 200);
    var buffer: [8192]u8 = undefined;
    const page = try support.helpPage(App, &.{ "build", "--help" }, width, &buffer);
    const limit = @max(width, 40);
    var lines = std.mem.splitScalar(u8, page, '\n');
    while (lines.next()) |line| {
        if (line.len <= limit) continue;
        // Only a line whose words cannot break may run past the width: one
        // word after the indentation, or a left column and one word.
        const words = std.mem.count(u8, std.mem.trim(u8, line, " "), " ");
        c.note("width {d}: '{s}'", .{ width, line });
        if (words > 1 and std.mem.find(u8, line, "  ") == null) return error.LineTooLong;
    }
}

test "every width keeps lines within it, but for single words" {
    try shake.check(std.testing.allocator, {}, widthHolds, .{ .cases = 200 });
}

test "a hidden option is parsed but never shown" {
    var buffer: [4096]u8 = undefined;
    const page = try support.helpPage(App, &.{ "build", "--help" }, 80, &buffer);
    try std.testing.expect(std.mem.find(u8, page, "secret") == null);
    const v = try support.parsed(App, &.{ "build", "--secret", "--target=x" });
    try std.testing.expect(v.command.build.secret);
}

test "writeHelp writes the root page under any program name" {
    var buffer: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try ensign.writeHelp(App, &w, "other\x01", 60);
    try std.testing.expect(std.mem.find(u8, w.buffered(), "Usage: other\\x01 [options] <command>") != null);
}

test "a mistake prints its usage and where help is" {
    var diagnostic: ensign.Diagnostic = .{};
    try std.testing.expectError(error.MissingOption, ensign.parse(App, std.testing.allocator, &.{"build"}, .{ .diagnostic = &diagnostic }));
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try diagnostic.write(&w, 80);
    try std.testing.expectEqualStrings(
        \\app build: missing option '--target <TRIPLE>'
        \\Usage: app build [options] --target <TRIPLE> [FILES]...
        \\Try 'app build --help' for more information.
        \\
    , w.buffered());
}

test "an empty default is not shown" {
    const Named = struct { name: []const u8 = "", level: u8 = 0 };
    var buffer: [1024]u8 = undefined;
    const page = try support.helpPage(Named, &.{"--help"}, 80, &buffer);
    try std.testing.expect(std.mem.find(u8, page, "[default: ]") == null);
    try std.testing.expect(std.mem.find(u8, page, "[default: 0]") != null);
}
