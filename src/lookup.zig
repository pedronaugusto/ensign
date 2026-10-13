//! Names to numbers, a table built at compile time: one hash of the name and
//! usually one comparison, however many names share a length. A table of a
//! few names compares them in turn.
const std = @import("std");
const text = @import("text.zig");

pub const Entry = struct { []const u8, u16 };

/// A table of `entries`, whose names are distinct.
pub fn Table(comptime entries: []const Entry) type {
    return struct {
        /// A power of two at least twice the entries, so probes stay short.
        const size = blk: {
            var n: usize = 1;
            while (n < entries.len * 2) n *= 2;
            break :blk n;
        };
        const Slot = struct { name: []const u8 = "", value: u16 = 0, used: bool = false };
        const slots = blk: {
            @setEvalBranchQuota(text.branch_quota);
            var out: [size]Slot = @splat(.{});
            for (entries) |entry| {
                var at = hash(entry[0]) & (size - 1);
                while (out[at].used) {
                    if (std.mem.eql(u8, out[at].name, entry[0])) @compileError("ensign: the name " ++ entry[0] ++ " is given twice");
                    at = (at + 1) & (size - 1);
                }
                out[at] = .{ .name = entry[0], .value = entry[1], .used = true };
            }
            break :blk out;
        };

        pub fn get(name: []const u8) ?u16 {
            if (entries.len == 0) return null;
            // A few names are faster compared than hashed.
            if (entries.len <= 8) {
                inline for (entries) |entry| {
                    if (name.len == entry[0].len and std.mem.eql(u8, name, entry[0])) return entry[1];
                }
                return null;
            }
            var at = hash(name) & (size - 1);
            while (slots[at].used) : (at = (at + 1) & (size - 1)) {
                if (std.mem.eql(u8, slots[at].name, name)) return slots[at].value;
            }
            return null;
        }
    };
}

/// FNV-1a: short names, no seed, the same at compile time and at run time.
fn hash(name: []const u8) usize {
    var h: u64 = 0xcbf29ce484222325;
    for (name) |c| h = (h ^ c) *% 0x100000001b3;
    return @truncate(h ^ (h >> 32));
}

test "a table finds every name and nothing else" {
    const T = Table(&.{ .{ "alpha", 1 }, .{ "beta", 2 }, .{ "gamma", 3 }, .{ "", 4 } });
    try std.testing.expectEqual(@as(?u16, 1), T.get("alpha"));
    try std.testing.expectEqual(@as(?u16, 3), T.get("gamma"));
    try std.testing.expectEqual(@as(?u16, 4), T.get(""));
    try std.testing.expectEqual(@as(?u16, null), T.get("delta"));
    try std.testing.expectEqual(@as(?u16, null), Table(&.{}).get("x"));
}
