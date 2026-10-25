//! One value from its text, the words that say what was expected, and the
//! text that parses back to a value.
const std = @import("std");
const text = @import("text.zig");
const kinds = @import("kinds.zig");
const Writer = std.Io.Writer;

/// One value read from its text, or what the text had to be.
pub fn Read(comptime V: type) type {
    return union(enum) {
        value: V,
        /// Completes "expected ...": the words for this mistake, which for
        /// an aegis value say what was out of range or too fine.
        refused: []const u8,
    };
}

/// Reads one value of `V`. Integers take an optional sign, `0x`, `0o` or
/// `0b`, and `_` between digits; enums take the tag with `-` or `_`; text
/// is taken as it is; an aegis duration or size takes aegis's text, an
/// aegis integer is checked by its type, and a type that reads itself is
/// read by its own `parse`.
pub fn read(comptime V: type, bytes: []const u8) Read(V) {
    const refused: Read(V) = .{ .refused = expected(V) };
    return switch (comptime kinds.of(V)) {
        .integer => if (std.fmt.parseInt(V, bytes, 0)) |v| .{ .value = v } else |_| refused,
        .float => if (std.fmt.parseFloat(V, bytes)) |v| .{ .value = v } else |_| refused,
        .boolean => if (boolean(bytes)) |v| .{ .value = v } else refused,
        .enumeration => if (Tags(V).map.get(bytes)) |v| .{ .value = v } else refused,
        .text => .{ .value = bytes },
        .checked => blk: {
            const C = kinds.Checked(V);
            const raw = std.fmt.parseInt(C.Repr, bytes, 0) catch break :blk refused;
            break :blk if (C.make(raw)) |v| .{ .value = v } else refused;
        },
        .duration, .size => if (V.parse(bytes)) |v| .{ .value = v } else |err| .{ .refused = Refusals(V).of(err) },
        .custom => if (kinds.Custom(V).parse(bytes)) |v| .{ .value = v } else |err| .{ .refused = kinds.Custom(V).refusal(err) },
        .none => @compileError("ensign: no parser for " ++ @typeName(V)),
    };
}

/// Reads one value of `V`; null when `bytes` is not one.
pub fn parse(comptime V: type, bytes: []const u8) ?V {
    return switch (read(V, bytes)) {
        .value => |v| v,
        .refused => null,
    };
}

/// What an aegis duration or size had to be, for each way its text fails.
fn Refusals(comptime V: type) type {
    return struct {
        const duration = kinds.of(V) == .duration;
        const bounds = std.fmt.comptimePrint("{s} from {f} to {f}", .{
            if (duration) "a duration" else "a size",
            V.fromRaw(std.math.minInt(V.aegis_scalar.representation)),
            V.fromRaw(std.math.maxInt(V.aegis_scalar.representation)),
        });
        const fine = if (duration) "a duration in whole " ++ @tagName(V.aegis_scalar.unit) ++ "s" else "a whole number of bytes";

        fn of(err: V.ParseError) []const u8 {
            return switch (err) {
                error.Malformed => expected(V),
                error.Overflow => bounds,
                error.Inexact => fine,
            };
        }
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
    const out = comptime switch (kinds.of(V)) {
        .integer => range(V, std.math.minInt(V), std.math.maxInt(V), false),
        .float => "a number",
        .boolean => "true or false",
        .enumeration => blk: {
            var list: []const u8 = "one of ";
            for (names(V), 0..) |name, n| list = list ++ (if (n == 0) "" else ", ") ++ name;
            break :blk list;
        },
        .text => "text",
        .checked => range(kinds.Checked(V).Repr, kinds.Checked(V).min, kinds.Checked(V).max, kinds.Checked(V).skips_zero),
        .duration => "a duration such as 30s or 1m30s",
        .size => "a size such as 4096, 64MiB or 1.5GB",
        .custom => kinds.Custom(V).expected,
        .none => @compileError("ensign: no parser for " ++ @typeName(V)),
    };
    return out;
}

fn range(comptime R: type, comptime min: R, comptime max: R, comptime skips_zero: bool) []const u8 {
    return std.fmt.comptimePrint("{s} from {d} to {d}", .{ if (skips_zero) "a nonzero integer" else "an integer", min, max });
}

/// Writes `v` as text `read` reads back to the same value.
pub fn write(comptime V: type, w: *Writer, v: V) Writer.Error!void {
    switch (comptime kinds.of(V)) {
        .integer => try w.print("{d}", .{v}),
        .float => try w.print("{e}", .{v}),
        .boolean => try w.writeAll(if (v) "true" else "false"),
        .enumeration => try w.writeAll(names(V)[enumIndex(V, v)]),
        .text => try w.writeAll(v),
        .checked => try w.print("{d}", .{v.raw()}),
        .duration, .size, .custom => try v.format(w),
        .none => @compileError("ensign: no writer for " ++ @typeName(V)),
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
