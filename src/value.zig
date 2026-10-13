//! One value from its text, the words that say what was expected, and the
//! text that parses back to a value.
const std = @import("std");
const text = @import("text.zig");
const Writer = std.Io.Writer;

/// Parses one value of `V`; null when `bytes` is not one. Integers take an
/// optional sign, `0x`, `0o` or `0b`, and `_` between digits; enums take the
/// tag with `-` or `_`; text is taken as it is.
pub fn parse(comptime V: type, bytes: []const u8) ?V {
    return switch (@typeInfo(V)) {
        .int => std.fmt.parseInt(V, bytes, 0) catch null,
        .float => std.fmt.parseFloat(V, bytes) catch null,
        .bool => boolean(bytes),
        .@"enum" => Tags(V).map.get(bytes),
        .pointer => bytes,
        else => @compileError("ensign: no parser for " ++ @typeName(V)),
    };
}

/// `true`, `false`, `yes`, `no`, `on`, `off`, `1` and `0`.
pub fn boolean(bytes: []const u8) ?bool {
    const words = std.StaticStringMap(bool).initComptime(.{
        .{ "true", true }, .{ "false", false }, .{ "yes", true }, .{ "no", false },
        .{ "on", true },   .{ "off", false },   .{ "1", true },   .{ "0", false },
    });
    return words.get(bytes);
}

/// Every spelling of each tag of `E`.
fn Tags(comptime E: type) type {
    return struct {
        const map = blk: {
            @setEvalBranchQuota(text.branch_quota);
            const tag_names = @typeInfo(E).@"enum".field_names;
            var kvs: [tag_names.len * 2]struct { []const u8, E } = undefined;
            var len: usize = 0;
            for (tag_names) |name| {
                kvs[len] = .{ name, @field(E, name) };
                len += 1;
                if (!std.mem.eql(u8, name, text.dashed(name))) {
                    kvs[len] = .{ text.dashed(name), @field(E, name) };
                    len += 1;
                }
            }
            break :blk std.StaticStringMap(E).initComptime(kvs[0..len]);
        };
    };
}

/// The names of `E`'s values as the command line spells them.
pub fn names(comptime E: type) []const []const u8 {
    const out = comptime blk: {
        @setEvalBranchQuota(text.branch_quota);
        var list: []const []const u8 = &.{};
        for (@typeInfo(E).@"enum".field_names) |name| list = list ++ .{text.dashed(name)};
        break :blk list;
    };
    return out;
}

/// What a value of `V` must be, completing "expected ...".
pub fn expected(comptime V: type) []const u8 {
    @setEvalBranchQuota(text.branch_quota);
    const out = comptime switch (@typeInfo(V)) {
        .int => std.fmt.comptimePrint("an integer from {d} to {d}", .{ std.math.minInt(V), std.math.maxInt(V) }),
        .float => "a number",
        .bool => "true or false",
        .@"enum" => blk: {
            var list: []const u8 = "one of ";
            for (names(V), 0..) |name, n| list = list ++ (if (n == 0) "" else ", ") ++ name;
            break :blk list;
        },
        .pointer => "text",
        else => @compileError("ensign: no parser for " ++ @typeName(V)),
    };
    return out;
}

/// Writes `v` as text `parse` reads back to the same value.
pub fn write(comptime V: type, w: *Writer, v: V) Writer.Error!void {
    switch (@typeInfo(V)) {
        .int => try w.print("{d}", .{v}),
        .float => try w.print("{e}", .{v}),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .@"enum" => try w.writeAll(names(V)[enumIndex(V, v)]),
        .pointer => try w.writeAll(v),
        else => @compileError("ensign: no writer for " ++ @typeName(V)),
    }
}

/// The position of `v` among `E`'s declared tags.
pub fn enumIndex(comptime E: type, v: E) usize {
    inline for (@typeInfo(E).@"enum".field_names, 0..) |name, n| {
        if (v == @field(E, name)) return n;
    }
    unreachable; // unreachable: an exhaustive switch over the tags of E, which every value of E is one of
}

/// The nearest enum spelling to a mistyped one.
pub fn suggest(comptime E: type, typed: []const u8) ?[]const u8 {
    var nearest: text.Nearest = .{ .typed = typed };
    inline for (comptime names(E)) |name| nearest.consider(name);
    return nearest.best;
}

test "values" {
    const Color = enum { auto, always_on };
    try std.testing.expectEqual(@as(?u8, 255), parse(u8, "0xff"));
    try std.testing.expectEqual(@as(?u8, null), parse(u8, "256"));
    try std.testing.expectEqual(@as(?i32, -1_000), parse(i32, "-1_000"));
    try std.testing.expectEqual(@as(?Color, .always_on), parse(Color, "always-on"));
    try std.testing.expectEqual(@as(?Color, .always_on), parse(Color, "always_on"));
    try std.testing.expectEqual(@as(?Color, null), parse(Color, "Auto"));
    try std.testing.expectEqualStrings("an integer from 0 to 255", expected(u8));
    try std.testing.expectEqualStrings("one of auto, always-on", expected(Color));
    try std.testing.expectEqualStrings("always-on", suggest(Color, "alway-on").?);
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try write(f64, &w, 0.1);
    try std.testing.expectEqual(@as(?f64, 0.1), parse(f64, w.buffered()));
}
