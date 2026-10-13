const std = @import("std");
const ensign = @import("../ensign.zig");

const Color = enum { auto, always, never };

const Build = struct {
    release: bool = false,
    jobs: u16 = 0,
    target: ?[]const u8 = null,
    files: []const []const u8 = &.{},

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Build the project",
        .options = .{
            .release = .{ .short = 'r', .help = "Optimize for speed" },
            .jobs = .{ .short = 'j', .help = "Parallel jobs", .env = "APP_JOBS" },
            .files = .{ .positional = true, .help = "Files to build", .hint = .file },
        },
    };
};

pub const Cli = struct {
    verbose: u8 = 0,
    color: Color = .auto,
    command: union(enum) { build: Build, stop },

    pub const spec: ensign.Spec(@This()) = .{
        .name = "app",
        .version = "1.0.0",
        .about = "An example",
        .options = .{
            .verbose = .{ .short = 'v', .count = true, .global = true, .help = "More output" },
            .color = .{ .help = "When to colour", .global = true },
        },
        .commands = .{ .build = .{ .aliases = &.{"b"} } },
    };
};

test "smoke" {
    const gpa = std.testing.allocator;
    const out = try ensign.parse(Cli, gpa, &.{ "-v", "build", "-rj4", "--color=never", "-v", "a", "b" }, .{});
    const cli = out.parsed;
    defer ensign.free(Cli, gpa, &cli);
    try std.testing.expectEqual(@as(u8, 2), cli.verbose);
    try std.testing.expectEqual(Color.never, cli.color);
    const b = cli.command.build;
    try std.testing.expect(b.release);
    try std.testing.expectEqual(@as(u16, 4), b.jobs);
    try std.testing.expectEqual(@as(usize, 2), b.files.len);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try ensign.writeHelp(Cli, &w, "app", 80);
    std.debug.print("{s}\n---\n", .{w.buffered()});
    const h = try ensign.parse(Cli, gpa, &.{ "build", "--help" }, .{});
    w = .fixed(&buf);
    try h.help.write(&w, 60);
    std.debug.print("{s}\n---\n", .{w.buffered()});
    var d: ensign.Diagnostic = .{};
    try std.testing.expectError(error.UnknownOption, ensign.parse(Cli, gpa, &.{ "build", "--relase" }, .{ .diagnostic = &d }));
    w = .fixed(&buf);
    try d.write(&w, 80);
    std.debug.print("{s}\n", .{w.buffered()});
}
