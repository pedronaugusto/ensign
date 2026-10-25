//! A required group with a required option in it: refused, the group always holds one.
const std = @import("std");
const ensign = @import("ensign");
const T = struct {
    token: []const u8,
    password: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{ .required_groups = &.{&.{ .token, .password }} };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
