//! A list positional before another: where would the list end?
const std = @import("std");
const ensign = @import("ensign");
const T = struct {
    sources: []const []const u8 = &.{},
    destination: []const u8,
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .sources = .{ .positional = true }, .destination = .{ .positional = true } } };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
