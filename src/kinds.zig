//! What a value's type is on the command line: one of Zig's scalars, or one
//! of aegis's checked scalars. An aegis type is recognized by the
//! `aegis_scalar` declaration aegis puts on each, which also states its
//! parameters, never by its name or by rebuilding it: a program pinning
//! another aegis version than ensign's builds another copy of aegis, whose
//! types are never equal to the ones ensign's copy makes, while the
//! declaration reads the same in both. A value is made only through the
//! type's own checked functions, as the declaration's contract names them.
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
        .@"enum" => |e| if (family(V)) |f| ofFamily(f) else if (e.mode == .exhaustive) .enumeration else .none,
        .@"struct" => if (family(V)) |f| ofFamily(f) else .none,
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
