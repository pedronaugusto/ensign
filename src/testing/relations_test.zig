//! Relations between options: an option that requires others, groups of
//! which one is required, and values an option implies; their precedence
//! against the command line and the environment, their messages, help, and
//! render writing what they need.
const std = @import("std");
const shake = @import("shakedown");
const ensign = @import("../ensign.zig");
const support = @import("support.zig");

const Color = enum { auto, always, never };

const Serve = struct {
    key: ?[]const u8 = null,
    cert: ?[]const u8 = null,
    ca: ?[]const u8 = null,
    token: ?[]const u8 = null,
    password: ?[]const u8 = null,
    ci: bool = false,
    color: Color = .auto,
    progress: bool = true,
    jobs: u16 = 0,
    quiet: bool = false,

    pub const spec: ensign.Spec(@This()) = .{
        .name = "serve",
        .options = .{
            .key = .{ .env = "SERVE_KEY", .help = "The private key" },
            .cert = .{ .value_name = "PATH", .env = "SERVE_CERT" },
            .ci = .{ .help = "Run as CI does" },
            .color = .{ .env = "SERVE_COLOR" },
            .quiet = .{ .short = 'q' },
        },
        .requires = &.{.{ .option = .key, .needs = &.{ .cert, .ca } }},
        .required_groups = &.{&.{ .token, .password }},
        .conflicts = &.{&.{ .token, .password }},
        .implies = &.{
            .{ .option = .ci, .sets = .{ .color = .never, .progress = false, .quiet = true } },
            .{ .option = .quiet, .sets = .{ .jobs = 1 } },
        },
    };
};

test "an option given needs what it requires" {
    _ = try support.parsed(Serve, &.{ "--token=t", "--key=k", "--cert=c", "--ca=a" });
    _ = try support.parsed(Serve, &.{ "--token=t", "--cert=c" });
    try support.fails(Serve, &.{ "--token=t", "--key=k" }, error.MissingOption, "serve: '--key' needs '--cert <PATH>' (or set SERVE_CERT)");
    try support.fails(Serve, &.{ "--token=t", "--key=k", "--cert=c" }, error.MissingOption, "serve: '--key' needs '--ca <CA>'");
}

test "the environment gives an option and what it requires alike" {
    var env = try support.environ(&.{ .{ "SERVE_KEY", "k" }, .{ "SERVE_CERT", "c" } });
    defer env.deinit();
    try support.failsWith(Serve, &.{"--token=t"}, .{ .environ = &env }, error.MissingOption, "serve: '--key' needs '--ca <CA>'");
    const v = try support.parsedWith(Serve, &.{ "--token=t", "--ca=a" }, .{ .environ = &env });
    try std.testing.expectEqualStrings("c", v.cert.?);
}

test "a required group takes one of its options, and with a conflict exactly one" {
    try support.fails(Serve, &.{}, error.MissingOption, "serve: missing one of '--token', '--password'");
    _ = try support.parsed(Serve, &.{"--password=p"});
    try support.fails(Serve, &.{ "--token=t", "--password=p" }, error.Conflict, "serve: '--token' cannot be used with '--password'");
}

test "an option implies values, below the command line and the environment" {
    const v = try support.parsed(Serve, &.{ "--token=t", "--ci" });
    try std.testing.expectEqual(Color.never, v.color);
    try std.testing.expect(!v.progress);
    try std.testing.expect(v.quiet);
    // An implied option implies in turn.
    try std.testing.expectEqual(@as(u16, 1), v.jobs);
    const given = try support.parsed(Serve, &.{ "--token=t", "--ci", "--color=always", "--jobs=8" });
    try std.testing.expectEqual(Color.always, given.color);
    try std.testing.expectEqual(@as(u16, 8), given.jobs);
    var env = try support.environ(&.{.{ "SERVE_COLOR", "always" }});
    defer env.deinit();
    const from_env = try support.parsedWith(Serve, &.{ "--token=t", "--ci" }, .{ .environ = &env });
    try std.testing.expectEqual(Color.always, from_env.color);
    const plain = try support.parsed(Serve, &.{"--token=t"});
    try std.testing.expectEqual(Color.auto, plain.color);
    try std.testing.expect(plain.progress);
}

test "help names what an option requires and implies, and the usage line its required groups" {
    var buffer: [4096]u8 = undefined;
    const page = try support.helpPage(Serve, &.{"--help"}, 200, &buffer);
    try std.testing.expect(std.mem.find(u8, page, "Usage: serve [options] <--token|--password>\n") != null);
    try std.testing.expect(std.mem.find(u8, page, "The private key [env: SERVE_KEY] [requires: --cert, --ca]") != null);
    try std.testing.expect(std.mem.find(u8, page, "Run as CI does [implies: --color=never, --no-progress, --quiet]") != null);
}

fn generate(s: *shake.Source) Serve {
    var v: Serve = .{};
    const words = [_][]const u8{ "a", "b", "c" };
    if (shake.gen.boolean(s)) v.key = shake.gen.oneOf(s, []const u8, &words);
    if (shake.gen.boolean(s)) v.cert = shake.gen.oneOf(s, []const u8, &words);
    if (shake.gen.boolean(s)) v.ca = shake.gen.oneOf(s, []const u8, &words);
    if (v.key != null) {
        v.cert = v.cert orelse "c";
        v.ca = v.ca orelse "a";
    }
    if (shake.gen.boolean(s)) v.token = "t" else v.password = "p";
    v.ci = shake.gen.boolean(s);
    v.color = shake.gen.enumValue(s, Color);
    v.progress = shake.gen.boolean(s);
    v.quiet = shake.gen.boolean(s);
    v.jobs = shake.gen.intRange(s, u16, 0, 3);
    return v;
}

fn roundTrip(_: void, c: *shake.Case) !void {
    const v = generate(c.source);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const args = try ensign.render(Serve, arena.allocator(), v);
    for (args) |a| c.note("arg '{s}'", .{a});
    const back = try support.parsed(Serve, args);
    try std.testing.expect(std.meta.eql(v.ci, back.ci));
    try std.testing.expectEqual(v.color, back.color);
    try std.testing.expectEqual(v.progress, back.progress);
    try std.testing.expectEqual(v.quiet, back.quiet);
    try std.testing.expectEqual(v.jobs, back.jobs);
    try std.testing.expectEqual(v.key == null, back.key == null);
    try std.testing.expectEqual(v.token == null, back.token == null);
}

test "render writes what the relations need, and the value parses back to itself" {
    try shake.check(std.testing.allocator, {}, roundTrip, .{ .cases = 2000 });
}

test "a declaration without relations does no relation work" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const T = struct { a: bool = false, b: ?[]const u8 = null };
    _ = try ensign.parse(T, failing.allocator(), &.{ "--a", "--b=x" }, .{});
}
