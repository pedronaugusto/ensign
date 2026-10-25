//! A relation naming a positional: refused, relations name options.
const std = @import("std");
const ensign = @import("ensign");
const T = struct {
    key: ?[]const u8 = null,
    file: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{
        .options = .{ .file = .{ .positional = true } },
        .requires = &.{.{ .option = .key, .needs = &.{.file} }},
    };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
