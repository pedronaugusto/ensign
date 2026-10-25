//! Types that read themselves: an `ensign_value` declaration naming the
//! type's own `parse`, and `format` writing it back. Reading in every
//! spelling, the words each mistake gives, help defaults, the environment,
//! lists, completions, render, and a property over the round trip.
const std = @import("std");
const shake = @import("shakedown");
const ensign = @import("../ensign.zig");
const support = @import("support.zig");
const tree = @import("../complete/tree.zig");

/// An IPv4 address and port, as `10.0.0.1:8080`: a struct that parses with
/// an error union and names the words for one of its errors.
const Address = struct {
    octets: [4]u8,
    port: u16,

    pub const ensign_value = .{
        .contract = 1,
        .expected = "an address such as 10.0.0.1:8080",
        .parse = parse,
        .refused = .{ .PortRange = "a port from 1 to 65535" },
    };

    pub const ParseError = error{ Malformed, PortRange };

    pub fn parse(bytes: []const u8) ParseError!Address {
        const colon = std.mem.findScalarLast(u8, bytes, ':') orelse return error.Malformed;
        var out: Address = .{ .octets = undefined, .port = 0 };
        var parts = std.mem.splitScalar(u8, bytes[0..colon], '.');
        for (&out.octets) |*octet| octet.* = std.fmt.parseInt(u8, parts.next() orelse return error.Malformed, 10) catch return error.Malformed;
        if (parts.next() != null) return error.Malformed;
        const port = std.fmt.parseInt(u32, bytes[colon + 1 ..], 10) catch return error.Malformed;
        if (port == 0 or port > 65535) return error.PortRange;
        out.port = @intCast(port);
        return out;
    }

    pub fn format(a: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}:{d}", .{ a.octets[0], a.octets[1], a.octets[2], a.octets[3], a.port });
    }
};

/// A level written as a word or a number: an enum whose own reading replaces
/// the tag names, with an optional `parse`.
const Level = enum(u8) {
    quiet = 0,
    normal = 1,
    loud = 2,

    pub const ensign_value = .{ .contract = 1, .expected = "a level: quiet, normal, loud or 0 to 2", .parse = parse };

    pub fn parse(bytes: []const u8) ?Level {
        if (std.fmt.parseInt(u8, bytes, 10)) |n| return std.enums.fromInt(Level, n) else |_| {}
        return std.meta.stringToEnum(Level, bytes);
    }

    pub fn format(l: Level, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(@tagName(l));
    }
};

/// A tagged union: either a name, borrowed from the argument, or a number.
const Target = union(enum) {
    name: []const u8,
    index: u32,

    pub const ensign_value = .{ .contract = 1, .expected = "a name or #index", .parse = parse };

    pub fn parse(bytes: []const u8) error{Empty}!Target {
        if (bytes.len == 0) return error.Empty;
        if (bytes[0] == '#') if (std.fmt.parseInt(u32, bytes[1..], 10)) |n| return .{ .index = n } else |_| {};
        return .{ .name = bytes };
    }

    pub fn format(t: Target, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (t) {
            .name => |n| try w.writeAll(n),
            .index => |n| try w.print("#{d}", .{n}),
        }
    }
};

const Serve = struct {
    listen: Address = .{ .octets = .{ 127, 0, 0, 1 }, .port = 8080 },
    peer: ?Address = null,
    level: Level = .normal,
    peers: []const Address = &.{},
    target: ?Target = null,
    upstream: ?Address = null,

    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .listen = .{ .short = 'l', .help = "Where to listen" },
        .peers = .{ .delimiter = ',' },
        .upstream = .{ .env = "UPSTREAM" },
        .target = .{ .positional = true },
    } };
};

test "a type that reads itself is read by its own parse, in every spelling" {
    const v = try support.parsed(Serve, &.{ "--listen=0.0.0.0:80", "--peer", "10.0.0.2:9000", "--level=2", "--peers=1.1.1.1:1,2.2.2.2:2", "#7" });
    defer ensign.free(Serve, std.testing.allocator, &v);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, v.listen.octets);
    try std.testing.expectEqual(@as(u16, 80), v.listen.port);
    try std.testing.expectEqual(@as(u16, 9000), v.peer.?.port);
    try std.testing.expectEqual(Level.loud, v.level);
    try std.testing.expectEqual(2, v.peers.len);
    try std.testing.expectEqual(@as(u8, 2), v.peers[1].octets[3]);
    try std.testing.expectEqual(@as(u32, 7), v.target.?.index);
    const short = try support.parsed(Serve, &.{ "-l10.1.2.3:4", "web" });
    try std.testing.expectEqual(@as(u16, 4), short.listen.port);
    try std.testing.expectEqualStrings("web", short.target.?.name);
    // Its own reading replaces the enum's tag names, and takes them too.
    try std.testing.expectEqual(Level.quiet, (try support.parsed(Serve, &.{"--level=quiet"})).level);
}

test "a mistake says what the type expected, in its words for each error" {
    try support.fails(Serve, &.{"--listen=localhost"}, error.InvalidValue, "program: invalid value 'localhost' for '--listen': expected an address such as 10.0.0.1:8080");
    try support.fails(Serve, &.{"--listen=1.2.3.4:0"}, error.InvalidValue, "program: invalid value '1.2.3.4:0' for '--listen': expected a port from 1 to 65535");
    try support.fails(Serve, &.{"--level=9"}, error.InvalidValue, "program: invalid value '9' for '--level': expected a level: quiet, normal, loud or 0 to 2");
    try support.fails(Serve, &.{"--peer"}, error.MissingValue, "program: '--peer' needs a value: an address such as 10.0.0.1:8080");
    try support.fails(Serve, &.{"--peers=1.1.1.1:1,x"}, error.InvalidValue, "program: invalid value 'x' for '--peers': expected an address such as 10.0.0.1:8080");
}

test "the environment gives a type that reads itself in the same text" {
    var env = try support.environ(&.{.{ "UPSTREAM", "9.9.9.9:53" }});
    defer env.deinit();
    const v = try support.parsedWith(Serve, &.{}, .{ .environ = &env });
    try std.testing.expectEqual(@as(u16, 53), v.upstream.?.port);
    var bad = try support.environ(&.{.{ "UPSTREAM", "9.9.9.9:99999" }});
    defer bad.deinit();
    try support.failsWith(Serve, &.{}, .{ .environ = &bad }, error.InvalidValue, "program: invalid value '9.9.9.9:99999' in UPSTREAM for '--upstream': expected a port from 1 to 65535");
}

test "help shows a default in the type's own text" {
    var buffer: [2048]u8 = undefined;
    const page = try support.helpPage(Serve, &.{"--help"}, 100, &buffer);
    try std.testing.expect(std.mem.find(u8, page, "Where to listen [default: 127.0.0.1:8080]") != null);
    try std.testing.expect(std.mem.find(u8, page, "[default: normal]") != null);
    // Its values are its own: help lists no tags for an enum that reads itself.
    try std.testing.expect(std.mem.find(u8, page, "possible values") == null);
}

test "completions take a type that reads itself as free text" {
    const nodes = comptime tree.nodes(Serve);
    try std.testing.expectEqual(tree.Kind.text, nodes[0].entries[0].kind);
    try std.testing.expectEqual(tree.Kind.text, nodes[0].positionals[0].kind);
}

test "parsing a type that reads itself allocates nothing" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const outcome = try ensign.parse(Serve, failing.allocator(), &.{ "--listen=1.2.3.4:5", "--level=loud", "x" }, .{});
    try std.testing.expectEqual(@as(u16, 5), outcome.parsed.listen.port);
}

fn generate(s: *shake.Source) Serve {
    var v: Serve = .{};
    if (shake.gen.boolean(s)) v.listen = .{ .octets = .{ shake.gen.int(s, u8), shake.gen.int(s, u8), shake.gen.int(s, u8), shake.gen.int(s, u8) }, .port = shake.gen.intRange(s, u16, 1, 65535) };
    if (shake.gen.boolean(s)) v.peer = .{ .octets = @splat(shake.gen.int(s, u8)), .port = shake.gen.intRange(s, u16, 1, 65535) };
    v.level = shake.gen.enumValue(s, Level);
    if (shake.gen.boolean(s)) v.target = .{ .index = shake.gen.int(s, u32) };
    return v;
}

fn roundTrip(_: void, c: *shake.Case) !void {
    const v = generate(c.source);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const args = try ensign.render(Serve, arena.allocator(), v);
    const back = try support.parsed(Serve, args);
    defer ensign.free(Serve, std.testing.allocator, &back);
    try std.testing.expectEqual(v.listen, back.listen);
    try std.testing.expectEqual(v.peer, back.peer);
    try std.testing.expectEqual(v.level, back.level);
    try std.testing.expect(std.meta.eql(v.target, back.target));
}

test "a type that reads itself, written as a command line, parses back to itself" {
    try shake.check(std.testing.allocator, {}, roundTrip, .{ .cases = 2000 });
}

fn arbitrary(_: void, c: *shake.Case) !void {
    const bytes = try shake.gen.string(c.source, c.gpa, .{ .kind = .bytes, .max_len = 24 });
    var diagnostic: ensign.Diagnostic = .{};
    const args: []const []const u8 = &.{ "--listen", bytes, "--peers", bytes, bytes };
    if (ensign.parse(Serve, std.testing.allocator, args, .{ .diagnostic = &diagnostic })) |outcome| {
        ensign.free(Serve, std.testing.allocator, &outcome.parsed);
    } else |err| {
        try std.testing.expectEqual(error.InvalidValue, err);
        var line: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&line);
        try diagnostic.writeMessage(&w);
    }
}

test "arbitrary bytes are read by the type or refused with its words" {
    try shake.check(std.testing.allocator, {}, arbitrary, .{ .cases = 2000 });
}
