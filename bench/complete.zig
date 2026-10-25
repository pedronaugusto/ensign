//! The program side of dynamic completion, timed from outside against clap's
//! `CompleteEnv`: `git checkout --branch` completed by a completer, the
//! process started, answering and exiting (bench/clap/README.md has the
//! command). Run without `ENSIGN_COMPLETE`, it parses its arguments and exits.
const std = @import("std");
const ensign = @import("ensign");

fn branches(c: *ensign.Completion) ensign.Completion.Error!void {
    const names = [_][]const u8{ "main", "maint", "master", "next", "release-1.0", "release-1.1", "topic/one", "topic/two" };
    for (names) |name| if (std.mem.startsWith(u8, name, c.prefix)) try c.add(name, "");
}

const Git = struct {
    verbose: u8 = 0,
    command: ?union(enum) {
        checkout: struct {
            force: bool = false,
            branch: ?[]const u8 = null,
            pub const spec: ensign.Spec(@This()) = .{ .options = .{ .branch = .{ .short = 'b', .complete = branches } } };
        },
    } = null,
    pub const spec: ensign.Spec(@This()) = .{ .name = "git", .options = .{ .verbose = .{ .short = 'v', .count = true } } };
};

pub fn main(init: std.process.Init) void {
    const git = ensign.parseOrExit(Git, init);
    std.mem.doNotOptimizeAway(&git);
}
