//! A field whose type no argument spells.
const std = @import("std");
const ensign = @import("ensign");
const T = struct { point: struct { x: u8 } = .{ .x = 0 } };
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
