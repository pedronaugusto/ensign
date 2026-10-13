//! A positional beside subcommands: is `build` a command or a file?
const std = @import("std");
const ensign = @import("ensign");
const T = struct {
    file: ?[]const u8 = null,
    command: union(enum) { build },
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .file = .{ .positional = true } } };
};
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
