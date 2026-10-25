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

pub fn main(init: std.process.Init) !void {
    // `bay test` runs each benchmark program once with `--smoke`: the
    // declaration builds and a completion answers.
    var it = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = it.skip();
    if (it.next()) |first| if (std.mem.eql(u8, first, "--smoke")) {
        var buffer: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        const r = ensign.completionRequest(Git, "1:checkout:--branch", &.{ "checkout", "--branch", "ma" });
        var completion = r.completion(init.io, init.gpa, null, &w);
        try r.answer(&completion);
        if (!std.mem.startsWith(u8, w.buffered(), "main")) return error.SmokeAnswer;
        return;
    };
    const git = ensign.parseOrExit(Git, init);
    std.mem.doNotOptimizeAway(&git);
}
