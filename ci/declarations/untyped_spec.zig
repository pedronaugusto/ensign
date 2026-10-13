//! A spec without its type would let a misspelt field pass unseen.
const std = @import("std");
const ensign = @import("ensign");
const T = struct {
    level: u8 = 0,
    pub const spec = .{ .about = "Untyped" };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
