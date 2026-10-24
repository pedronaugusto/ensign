//! An aegis scalar of a later contract than ensign reads: refused by its
//! number, never read as contract 1.
const std = @import("std");
const ensign = @import("ensign");
const Jobs = enum(u16) {
    pub const aegis_scalar = .{ .contract = 2, .kind = .ranged, .representation = u16, .minimum = 1, .maximum = 64 };
    _,
};
const T = struct { jobs: ?Jobs = null };
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
