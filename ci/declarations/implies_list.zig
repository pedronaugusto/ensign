//! A list implied by an option: refused, an implied value is one value.
const std = @import("std");
const ensign = @import("ensign");
const T = struct {
    ci: bool = false,
    tags: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .implies = &.{.{ .option = .ci, .sets = .{ .tags = &.{"ci"} } }} };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
