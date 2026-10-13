//! A subcommand option spelled like a global one above it.
const std = @import("std");
const ensign = @import("ensign");
const Build = struct { color: bool = false };
const T = struct {
    color: bool = false,
    command: union(enum) { build: Build },
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .color = .{ .global = true } } };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
