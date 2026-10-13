//! Environment fallbacks: the command line, then the environment, then the default.
const std = @import("std");
const ensign = @import("../ensign.zig");
const support = @import("support.zig");

const T = struct {
    jobs: u16 = 1,
    color: enum { auto, never } = .auto,
    fast: bool = false,
    verbose: u8 = 0,
    paths: []const []const u8 = &.{"default"},
    token: []const u8,
    quiet: bool = false,
    loud: bool = false,
    command: ?union(enum) { run: struct {
        level: u8 = 0,
        pub const spec: ensign.Spec(@This()) = .{ .options = .{ .level = .{ .env = "APP_LEVEL" } } };
    } } = null,

    pub const spec: ensign.Spec(@This()) = .{
        .options = .{
            .jobs = .{ .env = "APP_JOBS", .global = true },
            .color = .{ .env = "APP_COLOR" },
            .fast = .{ .env = "APP_FAST" },
            .verbose = .{ .env = "APP_VERBOSE", .count = true },
            .paths = .{ .env = "APP_PATHS", .delimiter = ':' },
            .token = .{ .env = "APP_TOKEN" },
            .quiet = .{ .env = "APP_QUIET" },
            .loud = .{ .env = "APP_LOUD" },
        },
        .conflicts = &.{&.{ .quiet, .loud }},
    };
};

const all = [_][2][]const u8{
    .{ "APP_JOBS", "8" },      .{ "APP_COLOR", "never" },  .{ "APP_FAST", "yes" }, .{ "APP_VERBOSE", "2" },
    .{ "APP_PATHS", "a:b:c" }, .{ "APP_TOKEN", "secret" }, .{ "APP_LEVEL", "5" },
};

test "the environment fills what the command line leaves" {
    var environ = try support.environ(&all);
    defer environ.deinit();
    const v = try support.parsedWith(T, &.{"run"}, .{ .environ = &environ });
    defer ensign.free(T, std.testing.allocator, &v);
    try std.testing.expectEqual(@as(u16, 8), v.jobs);
    try std.testing.expectEqual(.never, v.color);
    try std.testing.expect(v.fast);
    try std.testing.expectEqual(@as(u8, 2), v.verbose);
    try std.testing.expectEqual(@as(usize, 3), v.paths.len);
    try std.testing.expectEqualStrings("secret", v.token);
    try std.testing.expectEqual(@as(u8, 5), v.command.?.run.level);
}

test "the command line wins over the environment" {
    var environ = try support.environ(&all);
    defer environ.deinit();
    const v = try support.parsedWith(T, &.{ "--jobs=2", "--paths=x", "--token=t", "--no-fast", "run", "--level=1", "--jobs=3" }, .{ .environ = &environ });
    defer ensign.free(T, std.testing.allocator, &v);
    try std.testing.expectEqual(@as(u16, 3), v.jobs);
    try std.testing.expect(!v.fast);
    try std.testing.expectEqual(@as(usize, 1), v.paths.len);
    try std.testing.expectEqualStrings("t", v.token);
    try std.testing.expectEqual(@as(u8, 1), v.command.?.run.level);
}

test "without the environment, defaults stand and required options are missing" {
    const v = try support.parsed(T, &.{"--token=t"});
    try std.testing.expectEqual(@as(u16, 1), v.jobs);
    try std.testing.expectEqualStrings("default", v.paths[0]);
    try support.fails(T, &.{}, error.MissingOption, "program: missing option '--token <TOKEN>' (or set APP_TOKEN)");
}

test "an empty variable counts as unset" {
    var environ = try support.environ(&.{ .{ "APP_TOKEN", "" }, .{ "APP_JOBS", "" } });
    defer environ.deinit();
    try support.failsWith(T, &.{}, .{ .environ = &environ }, error.MissingOption, "program: missing option '--token <TOKEN>' (or set APP_TOKEN)");
}

test "a bad value names its variable" {
    var environ = try support.environ(&.{ .{ "APP_TOKEN", "t" }, .{ "APP_JOBS", "many" } });
    defer environ.deinit();
    try support.failsWith(T, &.{}, .{ .environ = &environ }, error.InvalidValue, "program: invalid value 'many' in APP_JOBS for '--jobs': expected an integer from 0 to 65535");
    var colour = try support.environ(&.{ .{ "APP_TOKEN", "t" }, .{ "APP_COLOR", "nevr" } });
    defer colour.deinit();
    try support.failsWith(T, &.{}, .{ .environ = &colour }, error.InvalidValue, "program: invalid value 'nevr' in APP_COLOR for '--color': expected one of auto, never; did you mean 'never'?");
}

test "conflicts: the command line refuses both, and silences the environment" {
    try support.fails(T, &.{ "--token=t", "--loud", "--quiet" }, error.Conflict, "program: '--quiet' cannot be used with '--loud'");
    var environ = try support.environ(&.{ .{ "APP_TOKEN", "t" }, .{ "APP_QUIET", "1" } });
    defer environ.deinit();
    const v = try support.parsedWith(T, &.{"--loud"}, .{ .environ = &environ });
    try std.testing.expect(v.loud and !v.quiet);
    const w = try support.parsedWith(T, &.{}, .{ .environ = &environ });
    try std.testing.expect(w.quiet and !w.loud);
}
