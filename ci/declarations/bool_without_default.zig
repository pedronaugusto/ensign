//! A boolean with no default: absent would mean nothing.
const std = @import("std");
const ensign = @import("ensign");
const T = struct { force: bool };
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
