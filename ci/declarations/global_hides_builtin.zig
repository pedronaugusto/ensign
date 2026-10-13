//! A global short option above spelled like a subcommand's own version flag.
const std = @import("std");
const ensign = @import("ensign");
const Sub = struct {
    x: bool = false,
    pub const spec: ensign.Spec(@This()) = .{ .version = "2" };
};
const T = struct {
    level: u8 = 0,
    command: union(enum) { sub: Sub },
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .level = .{ .global = true, .short = 'V', .count = true } } };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
