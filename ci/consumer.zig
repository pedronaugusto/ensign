//! A consumer imports the one module and parses with it, needing nothing else.
const std = @import("std");
const ensign = @import("ensign");

const Args = struct {
    name: []const u8 = "world",
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .name = .{ .short = 'n' } } };
};

pub fn main(init: std.process.Init) void {
    const args = ensign.parseOrExit(Args, init);
    std.mem.doNotOptimizeAway(args.name.len);
}
