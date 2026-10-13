//! Two subcommand fields: which one would `build` select?
const std = @import("std");
const ensign = @import("ensign");
const T = struct {
    first: union(enum) { build },
    second: union(enum) { run },
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
