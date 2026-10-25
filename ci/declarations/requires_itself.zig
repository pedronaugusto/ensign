//! An option that requires itself: refused.
const std = @import("std");
const ensign = @import("ensign");
const T = struct {
    key: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{ .requires = &.{.{ .option = .key, .needs = &.{.key} }} };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
