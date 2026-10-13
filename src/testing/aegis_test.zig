//! aegis's checked scalars as values: ranged and checked integers, ids and
//! counts read as integers and checked by their type, durations and sizes in
//! aegis's text; what each mistake says, help defaults, completions, and
//! properties over their round trip and the edges of their ranges.
const std = @import("std");
const aegis = @import("aegis");
const shake = @import("shakedown");
const ensign = @import("../ensign.zig");
const support = @import("support.zig");
const tree = @import("../complete/tree.zig");

const Jobs = aegis.int.Ranged(u16, 1, 256);
const Timeout = aegis.units.Duration(.millisecond, u64);
const Size = aegis.units.Bytes(u64);
const Node = aegis.id.NonZero(struct {}, u32);
const Offset = aegis.id.NonZero(struct {}, i8);
const Kept = aegis.units.Count(struct {}, u8);
const Workers = aegis.int.Checked(u8);
const Spare = aegis.int.Saturating(i16);
const Delta = aegis.units.Duration(.nanosecond, i64);

const Run = struct {
    jobs: ?Jobs = null,
    timeout: Timeout = .fromRaw(30_000),
    max_size: Size = .fromRaw(64 << 20),
    node: ?Node = null,
    offset: ?Offset = null,
    keep: Kept = .fromRaw(3),
    workers: Workers = .init(4),
    spare: Spare = .init(0),
    delta: Delta = .fromRaw(0),
    waits: []const Timeout = &.{},
    limit: ?Size = null,
    budget: ?Timeout = null,

    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .jobs = .{ .short = 'j', .help = "Parallel jobs" },
        .timeout = .{ .help = "How long to wait" },
        .max_size = .{ .help = "The largest file" },
        .waits = .{ .delimiter = ',' },
        .limit = .{ .env = "LIMIT" },
        .budget = .{ .positional = true },
    } };
};

test "aegis integers are read as integers and checked by their type" {
    const v = try support.parsed(Run, &.{ "--jobs=256", "--node=0x10", "--offset=-128", "--keep=0b11", "--workers=255", "--spare=-1_000" });
    try std.testing.expectEqual(@as(u16, 256), v.jobs.?.raw());
    try std.testing.expectEqual(@as(u32, 16), v.node.?.raw());
    try std.testing.expectEqual(@as(i8, -128), v.offset.?.raw());
    try std.testing.expectEqual(@as(u8, 3), v.keep.raw());
    try std.testing.expectEqual(@as(u8, 255), v.workers.raw());
    try std.testing.expectEqual(@as(i16, -1000), v.spare.raw());
    try support.fails(Run, &.{"--jobs=0"}, error.InvalidValue, "program: invalid value '0' for '--jobs': expected an integer from 1 to 256");
    try support.fails(Run, &.{"-j257"}, error.InvalidValue, "program: invalid value '257' for '--jobs': expected an integer from 1 to 256");
    try support.fails(Run, &.{"-j"}, error.MissingValue, "program: '--jobs' needs a value: an integer from 1 to 256");
    try support.fails(Run, &.{"--node=0"}, error.InvalidValue, "program: invalid value '0' for '--node': expected an integer from 1 to 4294967295");
    try support.fails(Run, &.{"--offset=0"}, error.InvalidValue, "program: invalid value '0' for '--offset': expected a nonzero integer from -128 to 127");
    try support.fails(Run, &.{"--keep=256"}, error.InvalidValue, "program: invalid value '256' for '--keep': expected an integer from 0 to 255");
}

test "durations and sizes take aegis's text, exact and in range" {
    const v = try support.parsed(Run, &.{ "--timeout=1m30s", "--max-size", "1.5GB", "--waits=250ms,1s", "--delta=-1.5us", "2h" });
    defer ensign.free(Run, std.testing.allocator, &v);
    try std.testing.expectEqual(@as(u64, 90_000), v.timeout.raw());
    try std.testing.expectEqual(@as(u64, 1_500_000_000), v.max_size.raw());
    try std.testing.expectEqual(@as(usize, 2), v.waits.len);
    try std.testing.expectEqual(@as(u64, 1000), v.waits[1].raw());
    try std.testing.expectEqual(@as(i64, -1500), v.delta.raw());
    try std.testing.expectEqual(@as(u64, 7_200_000), v.budget.?.raw());
    try support.fails(Run, &.{"--timeout=30"}, error.InvalidValue, "program: invalid value '30' for '--timeout': expected a duration such as 30s or 1m30s");
    try support.fails(Run, &.{"--timeout=1.5ms"}, error.InvalidValue, "program: invalid value '1.5ms' for '--timeout': expected a duration in whole milliseconds");
    try support.fails(Run, &.{"--timeout=-1s"}, error.InvalidValue, "program: invalid value '-1s' for '--timeout': expected a duration from 0s to 213503982334d14h25m51s615ms");
    try support.fails(Run, &.{"--timeout"}, error.MissingValue, "program: '--timeout' needs a value: a duration such as 30s or 1m30s");
    try support.fails(Run, &.{"--max-size=1KB"}, error.InvalidValue, "program: invalid value '1KB' for '--max-size': expected a size such as 4096, 64MiB or 1.5GB");
    try support.fails(Run, &.{"--max-size=0.1KiB"}, error.InvalidValue, "program: invalid value '0.1KiB' for '--max-size': expected a whole number of bytes");
    try support.fails(Run, &.{"--max-size=16EiB"}, error.InvalidValue, "program: invalid value '16EiB' for '--max-size': expected a size from 0B to 18446744073709551615B");
    try support.fails(Run, &.{"--waits=1s,x"}, error.InvalidValue, "program: invalid value 'x' for '--waits': expected a duration such as 30s or 1m30s");
    try support.fails(Run, &.{"5ms1s"}, error.InvalidValue, "program: invalid value '5ms1s' for '[BUDGET]': expected a duration such as 30s or 1m30s");
}

test "the environment gives aegis values in the same text" {
    var environ = try support.environ(&.{.{ "LIMIT", "2GiB" }});
    defer environ.deinit();
    const v = try support.parsedWith(Run, &.{}, .{ .environ = &environ });
    try std.testing.expectEqual(@as(u64, 2 << 30), v.limit.?.raw());
    var wrong = try support.environ(&.{.{ "LIMIT", "lots" }});
    defer wrong.deinit();
    try support.failsWith(Run, &.{}, .{ .environ = &wrong }, error.InvalidValue, "program: invalid value 'lots' in LIMIT for '--limit': expected a size such as 4096, 64MiB or 1.5GB");
}

test "help shows each default in its own text, and lists no values" {
    var buffer: [4096]u8 = undefined;
    const page = try support.helpPage(Run, &.{"--help"}, 120, &buffer);
    for ([_][]const u8{ "How long to wait [default: 30s]", "The largest file [default: 64MiB]", "[default: 3]", "[default: 4]" }) |want| {
        if (std.mem.find(u8, page, want) == null) {
            std.debug.print("{s}\nhas no '{s}'\n", .{ page, want });
            return error.TestExpectedText;
        }
    }
    try std.testing.expect(std.mem.find(u8, page, "possible") == null);
}

test "completions offer no values for an aegis value, and honour its hint" {
    const nodes = comptime tree.nodes(Run);
    inline for (nodes[0].entries) |entry| {
        if (comptime entry.kind != .flag) {
            try std.testing.expectEqual(tree.Kind.text, entry.kind);
            try std.testing.expectEqual(@as(usize, 0), entry.values.len);
        }
    }
    try std.testing.expectEqual(tree.Kind.text, nodes[0].positionals[0].kind);
}

test "render writes aegis values back in their own text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const args = try ensign.render(Run, arena.allocator(), .{
        .jobs = try Jobs.init(8),
        .timeout = .fromRaw(90_000),
        .max_size = .fromRaw(1 << 30),
        .workers = .init(5),
        .waits = &.{.fromRaw(250)},
        .budget = .fromRaw(1),
    });
    const want = [_][]const u8{ "--jobs=8", "--timeout=1m30s", "--max-size=1GiB", "--workers=5", "--waits=250ms", "1ms" };
    try std.testing.expectEqual(want.len, args.len);
    for (want, args) |w, a| try std.testing.expectEqualStrings(w, a);
}

fn generate(s: *shake.Source) Run {
    var v: Run = .{
        .timeout = .fromRaw(shake.gen.int(s, u64)),
        .max_size = .fromRaw(shake.gen.int(s, u64)),
        .keep = .fromRaw(shake.gen.int(s, u8)),
        .workers = .init(shake.gen.int(s, u8)),
        .spare = .init(shake.gen.int(s, i16)),
        .delta = .fromRaw(shake.gen.int(s, i64)),
    };
    if (shake.gen.boolean(s)) v.jobs = Jobs.init(shake.gen.intRange(s, u16, 1, 256)) catch unreachable; // unreachable: drawn from the range
    if (shake.gen.boolean(s)) v.node = Node.fromRaw(shake.gen.intRange(s, u32, 1, std.math.maxInt(u32))) catch unreachable; // unreachable: drawn above zero
    if (shake.gen.boolean(s)) v.limit = .fromRaw(shake.gen.int(s, u64) & ~@as(u64, (1 << 20) - 1));
    if (shake.gen.boolean(s)) v.budget = .fromRaw(shake.gen.int(s, u64));
    return v;
}

fn expectSame(want: Run, got: Run) !void {
    try std.testing.expectEqual(want.jobs, got.jobs);
    try std.testing.expectEqual(want.timeout, got.timeout);
    try std.testing.expectEqual(want.max_size, got.max_size);
    try std.testing.expectEqual(want.node, got.node);
    try std.testing.expectEqual(want.keep, got.keep);
    try std.testing.expect(std.meta.eql(want.workers, got.workers));
    try std.testing.expect(std.meta.eql(want.spare, got.spare));
    try std.testing.expectEqual(want.delta, got.delta);
    try std.testing.expectEqual(want.limit, got.limit);
    try std.testing.expectEqual(want.budget, got.budget);
}

fn roundTrip(_: void, c: *shake.Case) !void {
    const v = generate(c.source);
    const args = try ensign.render(Run, c.gpa, v);
    for (args) |a| c.note("arg '{s}'", .{a});
    const outcome = try ensign.parse(Run, c.gpa, args, .{});
    try expectSame(v, outcome.parsed);
}

test "an aegis value written as a command line parses back to itself" {
    try shake.check(std.testing.allocator, {}, roundTrip, .{ .cases = 2000 });
}

const Edges = struct {
    level: aegis.int.Ranged(i8, -5, 5) = .literal(0),
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .level = .{ .short = 'l' } } };
};

test "a ranged value takes every integer of its range and nothing past either end" {
    var buffer: [8]u8 = undefined;
    for (0..256) |n| {
        const raw: i16 = @as(i16, @intCast(n)) - 128;
        var w: std.Io.Writer = .fixed(&buffer);
        try w.print("{d}", .{raw});
        const text = w.buffered();
        const outcome = ensign.parse(Edges, std.testing.allocator, &.{ "-l", text }, .{});
        if (raw >= -5 and raw <= 5) {
            try std.testing.expectEqual(raw, (try outcome).parsed.level.raw());
        } else try std.testing.expectError(error.InvalidValue, outcome);
    }
    try support.fails(Edges, &.{"-l6"}, error.InvalidValue, "program: invalid value '6' for '--level': expected an integer from -5 to 5");
    try support.fails(Edges, &.{"-l-6"}, error.InvalidValue, "program: invalid value '-6' for '--level': expected an integer from -5 to 5");
}

fn sizeEdge(_: void, c: *shake.Case) !void {
    // A size at either end of the representation, or one past it, written in a unit.
    const units = [_]struct { u128, []const u8 }{ .{ 1, "B" }, .{ 1000, "kB" }, .{ 1 << 10, "KiB" }, .{ 1 << 30, "GiB" }, .{ 1_000_000_000_000_000_000, "EB" }, .{ 1 << 60, "EiB" } };
    const unit = units[shake.gen.intRange(c.source, usize, 0, units.len - 1)];
    const top = @as(u128, std.math.maxInt(u64)) / unit[0];
    const count = top - shake.gen.intRange(c.source, u8, 0, 2) + shake.gen.intRange(c.source, u8, 0, 2);
    const text = try c.gpa.print("--max-size={d}{s}", .{ count, unit[1] });
    c.note("{s}", .{text});
    const outcome = ensign.parse(Run, c.gpa, &.{text}, .{});
    if (count * unit[0] <= std.math.maxInt(u64)) {
        try std.testing.expectEqual(@as(u64, @intCast(count * unit[0])), (try outcome).parsed.max_size.raw());
    } else try std.testing.expectError(error.InvalidValue, outcome);
}

test "a size at the edge of its representation is taken, and one past it refused" {
    try shake.check(std.testing.allocator, {}, sizeEdge, .{ .cases = 500 });
}
