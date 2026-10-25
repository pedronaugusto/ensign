//! What a value's type is on the command line: one of Zig's scalars, one of
//! aegis's checked scalars, or a type that reads itself. An aegis type is
//! recognized by the
//! `aegis_scalar` declaration aegis puts on each, which also states its
//! parameters, never by its name or by rebuilding it: a program pinning
//! another aegis version than ensign's builds another copy of aegis, whose
//! types are never equal to the ones ensign's copy makes, while the
//! declaration reads the same in both. A value is made only through the
//! type's own checked functions, as the declaration's contract names them.
//! A type that reads itself says so the same way, in an `ensign_value`
//! declaration naming its own `parse`, and writes itself with std's `format`.
const std = @import("std");
const aegis = @import("aegis");

/// How a value is read and written.
pub const Kind = enum {
    integer,
    float,
    boolean,
    /// An exhaustive enum: one of its tags.
    enumeration,
    /// `[]const u8`, or any other pointer, which the declaration checks.
    text,
    /// An aegis integer that checks what it holds: `int.Ranged`, `Checked`
    /// and `Saturating`, `units.Count`, `id.Id` and `NonZero`.
    checked,
    /// `aegis.units.Duration`, in aegis's duration text: `30s`, `1m30s`.
    duration,
    /// `aegis.units.Bytes`, in aegis's size text: `4096`, `64MiB`.
    size,
    /// A type that reads itself: it declares `ensign_value`, naming its own
    /// `parse`, and writes itself with `format`.
    custom,
    /// No command line spells it: a non-exhaustive enum aegis does not
    /// publish as one of the above, an untagged aggregate, and the rest.
    none,
};

/// Each aegis scalar a command line gives, as its `aegis_scalar` literal
/// names it.
pub const Family = enum { ranged, checked, saturating, count, id, nonzero, duration, bytes };

/// The kind of `V`.
pub fn of(comptime V: type) Kind {
    return switch (@typeInfo(V)) {
        .int => .integer,
        .float => .float,
        .bool => .boolean,
        .pointer => .text,
        .@"enum" => |e| if (custom(V)) .custom else if (family(V)) |f| ofFamily(f) else if (e.mode == .exhaustive) .enumeration else .none,
        .@"struct", .@"union" => if (custom(V)) .custom else if (family(V)) |f| ofFamily(f) else .none,
        else => .none,
    };
}

fn ofFamily(f: Family) Kind {
    return switch (f) {
        .duration => .duration,
        .bytes => .size,
        else => .checked,
    };
}

/// The aegis scalar `V` is, or null, from whichever copy of aegis made it.
/// A contract other than 1, the one this ensign reads, does not compile:
/// its fields or functions may have changed. An `Instant` (a point on a clock), `Bits` and an id `Counter` have no
/// command-line text.
pub fn family(comptime V: type) ?Family {
    switch (@typeInfo(V)) {
        .@"struct", .@"enum" => {},
        else => return null,
    }
    if (!@hasDecl(V, "aegis_scalar")) return null;
    const scalar = V.aegis_scalar;
    if (@typeInfo(@TypeOf(scalar)) != .@"struct" or !@hasField(@TypeOf(scalar), "contract")) return null;
    if (scalar.contract != 1) @compileError(std.fmt.comptimePrint("ensign: {s} is an aegis scalar of contract {d}; this ensign reads contract 1", .{ @typeName(V), scalar.contract }));
    const name = @tagName(scalar.kind);
    return if (@hasField(Family, name)) @field(Family, name) else null;
}

/// Whether `V` reads itself: it declares `ensign_value`. The declaration is
/// checked here, so a mistake in it names the type: a contract other than 1,
/// the one this ensign reads, an `aegis_scalar` beside it, a `parse` of
/// another shape, a missing `format`, or words for an error `parse` never
/// returns.
pub fn custom(comptime V: type) bool {
    if (!@hasDecl(V, "ensign_value")) return false;
    const d = V.ensign_value;
    const D = @TypeOf(d);
    const where = "ensign: " ++ @typeName(V) ++ ".ensign_value";
    if (@typeInfo(D) != .@"struct") @compileError(where ++ " is a literal: .{ .contract = 1, .expected = \"...\", .parse = parse }");
    if (!@hasField(D, "contract")) @compileError(where ++ " names no contract; this ensign reads contract 1");
    if (d.contract != 1) @compileError(std.fmt.comptimePrint("{s} is of contract {d}; this ensign reads contract 1", .{ where, d.contract }));
    if (@hasDecl(V, "aegis_scalar")) @compileError(where ++ ": the type is also an aegis scalar, which ensign reads by aegis_scalar; declare one of them");
    if (!@hasField(D, "expected")) @compileError(where ++ " says nothing of what a value must be; give .expected, which completes \"expected ...\"");
    if (!@hasField(D, "parse")) @compileError(where ++ " names no parse function: .parse = fn ([]const u8) E!" ++ @typeName(V) ++ " or ?" ++ @typeName(V));
    _ = Custom(V).checked;
    if (!@hasDecl(V, "format") or @typeInfo(@TypeOf(V.format)) != .@"fn") @compileError(where ++ ": " ++ @typeName(V) ++ " has no format method, which help and render write it with: pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void");
    return true;
}

/// How a type that reads itself is read: its `parse`, what a value must be,
/// and the words for each error `parse` returns.
pub fn Custom(comptime V: type) type {
    const d = V.ensign_value;
    const where = "ensign: " ++ @typeName(V) ++ ".ensign_value.parse";
    const F = @typeInfo(@TypeOf(d.parse));
    if (F != .@"fn" or F.@"fn".param_types.len != 1 or F.@"fn".param_types[0] != []const u8)
        @compileError(where ++ " takes the argument's bytes: fn ([]const u8) E!" ++ @typeName(V) ++ " or ?" ++ @typeName(V));
    const R = F.@"fn".return_type orelse @compileError(where ++ " returns a type known at compile time");
    const shape: enum { errors, optional } = switch (@typeInfo(R)) {
        .error_union => |e| if (e.payload == V) .errors else @compileError(where ++ " returns " ++ @typeName(R) ++ ", not E!" ++ @typeName(V)),
        .optional => |o| if (o.child == V) .optional else @compileError(where ++ " returns " ++ @typeName(R) ++ ", not ?" ++ @typeName(V)),
        else => @compileError(where ++ " returns " ++ @typeName(R) ++ ": E!" ++ @typeName(V) ++ " or ?" ++ @typeName(V)),
    };
    return struct {
        /// What `parse` fails with: its error set, or `error{Refused}` for an optional.
        pub const Failure = if (shape == .errors) @typeInfo(R).error_union.error_set else error{Refused};
        /// Completes "expected ...".
        pub const expected: []const u8 = d.expected;

        /// Each error `.refused` names is one `parse` returns.
        pub const checked = blk: {
            if (@hasField(@TypeOf(d), "refused")) {
                if (shape == .optional) @compileError("ensign: " ++ @typeName(V) ++ ".ensign_value.refused names errors, and parse returns an optional");
                const names = @typeInfo(@TypeOf(d.refused)).@"struct".field_names;
                for (names) |name| {
                    const known = for (@typeInfo(Failure).error_set.error_names orelse &.{}) |e| {
                        if (std.mem.eql(u8, e, name)) break true;
                    } else false;
                    if (!known) @compileError("ensign: " ++ @typeName(V) ++ ".ensign_value.refused names error." ++ name ++ ", which parse never returns");
                }
            }
            break :blk true;
        };

        /// The value `bytes` hold, or what `parse` failed with.
        pub fn parse(bytes: []const u8) Failure!V {
            return if (shape == .errors) d.parse(bytes) else d.parse(bytes) orelse error.Refused;
        }

        /// The words for `err`: its own when the declaration gives them, else `expected`.
        pub fn refusal(err: Failure) []const u8 {
            if (@hasField(@TypeOf(d), "refused")) {
                switch (err) {
                    inline else => |e| if (@hasField(@TypeOf(d.refused), @errorName(e))) return @field(d.refused, @errorName(e)),
                }
            }
            return expected;
        }
    };
}

/// The integer a `checked` value of `V` is read as and written from, the
/// range it takes, and the value made from one.
pub fn Checked(comptime V: type) type {
    const f = family(V).?;
    return struct {
        pub const Repr = V.aegis_scalar.representation;
        pub const min: Repr = switch (f) {
            .ranged => V.aegis_scalar.minimum,
            .nonzero => if (@typeInfo(Repr).int.signedness == .unsigned) 1 else std.math.minInt(Repr),
            else => std.math.minInt(Repr),
        };
        pub const max: Repr = if (f == .ranged) V.aegis_scalar.maximum else std.math.maxInt(Repr);
        /// A signed `NonZero` takes both sides of zero but not zero itself.
        pub const skips_zero = f == .nonzero and @typeInfo(Repr).int.signedness == .signed;

        /// The value holding `raw`, or null where `V` refuses it.
        pub fn make(raw: Repr) ?V {
            return switch (f) {
                .ranged => V.init(raw) catch null,
                .nonzero => V.fromRaw(raw) catch null,
                .checked, .saturating => V.init(raw),
                .count, .id => V.fromRaw(raw),
                .duration, .bytes => unreachable, // unreachable: Checked is made only for the checked kind
            };
        }
    };
}

test "aegis's scalars are recognized by what they publish" {
    const Tag = struct {};
    try std.testing.expectEqual(Kind.checked, of(aegis.int.Ranged(u16, 1, 256)));
    try std.testing.expectEqual(Kind.checked, of(aegis.int.Checked(u7)));
    try std.testing.expectEqual(Kind.checked, of(aegis.id.NonZero(Tag, u64)));
    try std.testing.expectEqual(Kind.duration, of(aegis.units.Duration(.millisecond, u64)));
    try std.testing.expectEqual(Kind.duration, of(aegis.units.Duration(.nanosecond, i96)));
    try std.testing.expectEqual(Kind.size, of(aegis.units.Bytes(usize)));
    try std.testing.expectEqual(Kind.none, of(aegis.units.Bits(u64)));
    try std.testing.expectEqual(Kind.none, of(aegis.units.Instant(.awake, .second, i64)));
    try std.testing.expectEqual(Kind.none, of(aegis.id.Counter(Tag, u32)));
    try std.testing.expectEqual(Kind.none, of(enum(u16) {
        _,
        pub const Representation = u16;
    }));
    try std.testing.expectEqual(Kind.enumeration, of(enum { a, b }));
    try std.testing.expectEqual(Kind.none, of(enum(u8) { a, _ }));
    try std.testing.expectEqual(@as(u16, 1), Checked(aegis.int.Ranged(u16, 1, 256)).min);
    try std.testing.expect(Checked(aegis.id.NonZero(Tag, i8)).skips_zero);
}
