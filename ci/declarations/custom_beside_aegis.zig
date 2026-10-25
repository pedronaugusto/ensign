//! A type that declares both aegis_scalar and ensign_value: refused, since
//! one declaration owns how a type is read.
const std = @import("std");
const ensign = @import("ensign");
pub const Jobs = enum(u16) {
    pub const aegis_scalar = .{ .contract = 1, .kind = .ranged, .representation = u16, .minimum = 1, .maximum = 64 };
    pub const ensign_value = .{ .contract = 1, .expected = "jobs", .parse = parse };
    _,
    fn parse(bytes: []const u8) ?Jobs {
        return @fromBackingInt(@intCast(std.fmt.parseInt(u16, bytes, 10) catch return null));
    }
    pub fn format(j: Jobs, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}", .{@backingInt(j)});
    }
};
const T = struct { jobs: ?Jobs = null };
export fn reject() bool {
    return if (ensign.parse(T, std.heap.page_allocator, &.{}, .{})) |_| true else |_| false;
}
