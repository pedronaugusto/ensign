//! A non-exhaustive enum: its values beyond the tags have no names to read.
const std = @import("std");
const ensign = @import("ensign");
const T = struct { level: enum(u8) { low, high, _ } = .low };
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
