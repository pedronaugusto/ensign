//! A long name no shell can complete.
const std = @import("std");
const ensign = @import("ensign");
const T = struct { @"dry run": bool = false };
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
