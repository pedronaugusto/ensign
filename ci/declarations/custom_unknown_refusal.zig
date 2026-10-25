//! Words for an error `parse` never returns: refused, naming the error.
const std = @import("std");
const ensign = @import("ensign");
const Port = struct {
    n: u16,
    pub const ensign_value = .{ .contract = 1, .expected = "a port", .parse = parse, .refused = .{ .TooBig = "a port below 65536" } };
    fn parse(bytes: []const u8) error{Malformed}!Port {
        return .{ .n = std.fmt.parseInt(u16, bytes, 10) catch return error.Malformed };
    }
    pub fn format(p: Port, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}", .{p.n});
    }
};
const T = struct { port: ?Port = null };
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
