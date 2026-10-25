//! A `parse` that does not return the type: refused, naming the shape.
const std = @import("std");
const ensign = @import("ensign");
const Port = struct {
    n: u16,
    pub const ensign_value = .{ .contract = 1, .expected = "a port", .parse = parse };
    fn parse(bytes: []const u8) !u16 {
        return std.fmt.parseInt(u16, bytes, 10);
    }
    pub fn format(p: Port, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}", .{p.n});
    }
};
const T = struct { port: ?Port = null };
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
