//! A type that reads itself but cannot write itself back: refused, since help
//! and render write every value.
const std = @import("std");
const ensign = @import("ensign");
const Port = struct {
    n: u16,
    pub const ensign_value = .{ .contract = 1, .expected = "a port", .parse = parse };
    fn parse(bytes: []const u8) ?Port {
        return .{ .n = std.fmt.parseInt(u16, bytes, 10) catch return null };
    }
};
const T = struct { port: ?Port = null };
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
