//! Two options spelled `-j`.
const std = @import("std");
const ensign = @import("ensign");
const T = struct {
    jobs: u8 = 1,
    json: bool = false,
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .jobs = .{ .short = 'j' }, .json = .{ .short = 'j' } } };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
