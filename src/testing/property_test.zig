//! Properties over generated values and arguments: a value written as a
//! command line, in any of the spellings the syntax allows, parses back to
//! itself; arbitrary bytes are parsed or refused with a message; and a
//! suggestion always names an option there is.
const std = @import("std");
const ensign = @import("../ensign.zig");
const shake = @import("shakedown");

const Shade = enum { light, dark, very_dark };

const Inner = struct {
    depth: u16 = 0,
    flag: bool = false,
    item: ?[]const u8 = null,
    rest: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .depth = .{ .short = 'd' },
        .flag = .{ .short = 'f' },
        .item = .{ .positional = true },
        .rest = .{ .positional = true },
    } };
};

const Prop = struct {
    level: i32 = 0,
    ratio: f32 = 0,
    shade: Shade = .light,
    name: []const u8 = "",
    on: bool = false,
    off: bool = true,
    maybe: ?bool = null,
    count: u8 = 0,
    tags: []const []const u8 = &.{},
    nums: []const u16 = &.{},
    command: ?union(enum) { inner: Inner, bare } = null,

    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .level = .{ .short = 'l' },
        .name = .{ .short = 'n' },
        .on = .{ .short = 'o' },
        .count = .{ .short = 'c', .count = true, .global = true },
        .tags = .{ .short = 't' },
        .nums = .{ .delimiter = ',' },
    } };
};

fn text(s: *shake.Source, gpa: std.mem.Allocator) ![]u8 {
    return shake.gen.string(s, gpa, .{ .kind = .bytes, .max_len = 12 });
}

fn generate(s: *shake.Source, gpa: std.mem.Allocator) !Prop {
    var v: Prop = .{};
    if (shake.gen.boolean(s)) v.level = shake.gen.int(s, i32);
    if (shake.gen.boolean(s)) v.ratio = shake.gen.float(s, f32);
    v.shade = shake.gen.enumValue(s, Shade);
    if (shake.gen.boolean(s)) v.name = try text(s, gpa);
    v.on = shake.gen.boolean(s);
    v.off = shake.gen.boolean(s);
    v.maybe = if (shake.gen.boolean(s)) shake.gen.boolean(s) else null;
    v.count = shake.gen.intRange(s, u8, 0, 6);
    const tags = shake.gen.intRange(s, usize, 0, 3);
    var list = try gpa.alloc([]const u8, tags);
    for (list) |*t| t.* = try text(s, gpa);
    v.tags = list;
    v.nums = try shake.gen.slice(s, u16, struct {
        fn f(source: *shake.Source) u16 {
            return shake.gen.int(source, u16);
        }
    }.f, gpa, .{ .max_len = 4 });
    switch (shake.gen.intRange(s, u8, 0, 2)) {
        0 => {},
        1 => v.command = .bare,
        else => {
            var inner: Inner = .{ .depth = shake.gen.int(s, u16), .flag = shake.gen.boolean(s) };
            if (shake.gen.boolean(s)) {
                inner.item = try text(s, gpa);
                const rest = shake.gen.intRange(s, usize, 0, 3);
                list = try gpa.alloc([]const u8, rest);
                for (list) |*r| r.* = try text(s, gpa);
                inner.rest = list;
            }
            v.command = .{ .inner = inner };
        },
    }
    return v;
}

/// Writes `v` as a command line, choosing each spelling from the source:
/// long or short, value attached or separate, flags gathered into
/// clusters, and the global count before or after the subcommand.
const Writer = struct {
    s: *shake.Source,
    gpa: std.mem.Allocator,
    out: std.ArrayList([]const u8) = .empty,
    cluster: std.ArrayList(u8) = .empty,

    fn arg(w: *Writer, bytes: []const u8) !void {
        try w.flush();
        try w.out.append(w.gpa, bytes);
    }

    fn print(w: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try w.arg(try w.gpa.print(fmt, args));
    }

    /// A short flag, gathered with the ones before it when the source says so.
    fn short(w: *Writer, c: u8) !void {
        if (w.cluster.items.len == 0 or !shake.gen.boolean(w.s)) try w.flush();
        if (w.cluster.items.len == 0) try w.cluster.append(w.gpa, '-');
        try w.cluster.append(w.gpa, c);
    }

    fn flush(w: *Writer) !void {
        if (w.cluster.items.len == 0) return;
        try w.out.append(w.gpa, try w.cluster.toOwnedSlice(w.gpa));
    }

    /// An option with a value, in one of the four spellings.
    fn valued(w: *Writer, long: []const u8, short_name: ?u8, value: []const u8) !void {
        const form = shake.gen.intRange(w.s, u8, 0, 3);
        const c = short_name orelse 0;
        if (form == 0 or c == 0) return w.print("--{s}={s}", .{ long, value });
        if (form == 1) {
            try w.print("--{s}", .{long});
            return w.arg(value);
        }
        if (form == 2 or value.len == 0 or value[0] == '=') {
            try w.print("-{c}", .{c});
            return w.arg(value);
        }
        // Attached to its letter, after a cluster of flags or alone.
        try w.short(c);
        try w.cluster.appendSlice(w.gpa, value);
        try w.flush();
    }

    fn counts(w: *Writer, n: u8) !void {
        for (0..n) |_| if (shake.gen.boolean(w.s)) try w.short('c') else try w.arg("--count");
    }
};

fn written(s: *shake.Source, gpa: std.mem.Allocator, v: Prop) ![]const []const u8 {
    var w: Writer = .{ .s = s, .gpa = gpa };
    var counts_here = v.count;
    if (v.command != null) counts_here = shake.gen.intRange(s, u8, 0, v.count);
    try w.counts(counts_here);
    if (v.level != 0) try w.valued("level", 'l', try gpa.print("{d}", .{v.level}));
    if (@as(u32, @bitCast(v.ratio)) != 0) try w.valued("ratio", null, try gpa.print("{e}", .{v.ratio}));
    if (v.shade != .light) try w.valued("shade", null, if (v.shade == .dark) "dark" else if (shake.gen.boolean(s)) "very-dark" else "very_dark");
    if (v.name.len != 0) try w.valued("name", 'n', v.name);
    if (v.on) if (shake.gen.boolean(s)) try w.short('o') else try w.arg("--on");
    if (!v.off) if (shake.gen.boolean(s)) try w.arg("--no-off") else try w.arg("--off=false");
    if (v.maybe) |m| try w.arg(if (m) "--maybe" else "--no-maybe");
    for (v.tags) |t| try w.valued("tags", 't', t);
    if (v.nums.len != 0) {
        var joined: std.ArrayList(u8) = .empty;
        for (v.nums, 0..) |n, i| {
            if (i != 0) try joined.append(gpa, ',');
            try joined.print(gpa, "{d}", .{n});
        }
        try w.valued("nums", null, joined.items);
    }
    if (v.command) |command| switch (command) {
        .bare => {
            try w.arg("bare");
            try w.counts(v.count - counts_here);
        },
        .inner => |inner| {
            try w.arg("inner");
            try w.counts(v.count - counts_here);
            if (inner.depth != 0) try w.valued("depth", 'd', try gpa.print("{d}", .{inner.depth}));
            if (inner.flag) try w.short('f');
            if (inner.item) |item| {
                try w.arg("--");
                try w.arg(item);
                for (inner.rest) |r| try w.arg(r);
            }
        },
    };
    try w.flush();
    return w.out.items;
}

fn floatEqual(a: f32, b: f32) bool {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.isNan(a) and std.math.isNan(b);
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

fn expectSame(want: Prop, got: Prop) !void {
    try std.testing.expectEqual(want.level, got.level);
    try std.testing.expect(floatEqual(want.ratio, got.ratio));
    try std.testing.expectEqual(want.shade, got.shade);
    try std.testing.expectEqualStrings(want.name, got.name);
    try std.testing.expectEqual(want.on, got.on);
    try std.testing.expectEqual(want.off, got.off);
    try std.testing.expectEqual(want.maybe, got.maybe);
    try std.testing.expectEqual(want.count, got.count);
    try std.testing.expectEqual(want.tags.len, got.tags.len);
    for (want.tags, got.tags) |a, b| try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqualSlices(u16, want.nums, got.nums);
    try std.testing.expectEqual(want.command == null, got.command == null);
    const a = want.command orelse return;
    const b = got.command.?;
    try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    if (a == .bare) return;
    try std.testing.expectEqual(a.inner.depth, b.inner.depth);
    try std.testing.expectEqual(a.inner.flag, b.inner.flag);
    try std.testing.expectEqual(a.inner.item == null, b.inner.item == null);
    if (a.inner.item) |item| try std.testing.expectEqualStrings(item, b.inner.item.?);
    try std.testing.expectEqual(a.inner.rest.len, b.inner.rest.len);
    for (a.inner.rest, b.inner.rest) |x, y| try std.testing.expectEqualStrings(x, y);
}

fn roundTrip(_: void, c: *shake.Case) !void {
    const v = try generate(c.source, c.gpa);
    const args = try written(c.source, c.gpa, v);
    for (args) |a| c.note("arg '{f}'", .{std.zig.fmtString(a)});
    const outcome = try ensign.parse(Prop, c.gpa, args, .{});
    try expectSame(v, outcome.parsed);
    // ensign's own rendering, in the canonical spelling, also comes back.
    const canonical = try ensign.render(Prop, c.gpa, v);
    const again = try ensign.parse(Prop, c.gpa, canonical, .{});
    try expectSame(v, again.parsed);
}

test "a value written in any spelling parses back to itself" {
    try shake.check(std.testing.allocator, {}, roundTrip, .{ .cases = 2000 });
}

fn arbitrary(_: void, c: *shake.Case) !void {
    const pieces = [_][]const u8{ "-", "--", "-c", "-o", "-l", "-n", "-t", "-x", "--level", "--name=", "--shade", "--no-off", "--maybe=", "--nums", "inner", "bare", "-d", "-f", "1", "=", ",", "dark", "\xff", "\xed\xa0\x80", "--help", "-h" };
    const n = shake.gen.intRange(c.source, usize, 0, 8);
    const args = try c.gpa.alloc([]const u8, n);
    for (args) |*a| {
        a.* = if (shake.gen.boolean(c.source))
            shake.gen.oneOf(c.source, []const u8, &pieces)
        else
            try std.mem.concat(c.gpa, u8, &.{ shake.gen.oneOf(c.source, []const u8, &pieces), try shake.gen.string(c.source, c.gpa, .{ .kind = .bytes, .max_len = 4 }) });
    }
    var diagnostic: ensign.Diagnostic = .{};
    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    if (ensign.parse(Prop, std.testing.allocator, args, .{ .diagnostic = &diagnostic })) |outcome| switch (outcome) {
        .parsed => |v| ensign.free(Prop, std.testing.allocator, &v),
        .help => |h| try h.write(&w, 80),
        .version => return error.NoVersionDeclared,
        .complete => return error.CompletionUnasked,
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try diagnostic.write(&w, 80);
        if (diagnostic.suggestion) |s| try knownSpelling(s);
    }
}

/// A suggestion is an option, a negation, a command or an enum value there is.
fn knownSpelling(s: []const u8) !void {
    const known = [_][]const u8{ "--level", "--ratio", "--shade", "--name", "--on", "--off", "--no-off", "--maybe", "--no-maybe", "--count", "--tags", "--nums", "--help", "--depth", "--flag", "inner", "bare", "light", "dark", "very-dark" };
    for (known) |k| if (std.mem.eql(u8, k, s)) return;
    std.debug.print("suggested '{s}'\n", .{s});
    return error.UnknownSuggestion;
}

test "arbitrary arguments parse or are refused with a message, leaking nothing" {
    try shake.check(std.testing.allocator, {}, arbitrary, .{ .cases = 3000 });
}

fn typo(_: void, c: *shake.Case) !void {
    const names = [_][]const u8{ "level", "ratio", "shade", "name", "maybe", "count", "tags", "nums" };
    const name = shake.gen.oneOf(c.source, []const u8, &names);
    var bytes = try c.gpa.dupe(u8, name);
    // One edit: a changed, dropped or doubled letter.
    const at = shake.gen.intRange(c.source, usize, 0, bytes.len - 1);
    switch (shake.gen.intRange(c.source, u8, 0, 2)) {
        0 => bytes[at] = if (bytes[at] == 'z') 'y' else bytes[at] + 1,
        1 => bytes = try std.mem.concat(c.gpa, u8, &.{ bytes[0..at], bytes[at + 1 ..] }),
        else => bytes = try std.mem.concat(c.gpa, u8, &.{ bytes[0 .. at + 1], bytes[at..] }),
    }
    const arg = try std.mem.concat(c.gpa, u8, &.{ "--", bytes });
    c.note("typed '{s}'", .{arg});
    var diagnostic: ensign.Diagnostic = .{};
    if (ensign.parse(Prop, std.testing.allocator, &.{ arg, "1" }, .{ .diagnostic = &diagnostic })) |outcome| {
        // The edit made another option's name, or its negation.
        if (outcome == .parsed) ensign.free(Prop, std.testing.allocator, &outcome.parsed);
        return;
    } else |err| {
        if (err != error.UnknownOption) return;
        const s = diagnostic.suggestion orelse return error.NoSuggestion;
        try knownSpelling(s);
    }
}

test "a name one edit away from an option is answered with a suggestion" {
    try shake.check(std.testing.allocator, {}, typo, .{ .cases = 500 });
}
