//! Parsing from a slice, help and completion scripts build for
//! wasm32-freestanding in `zig build check-freestanding`: none of them needs
//! an operating system.
const std = @import("std");
const ensign = @import("ensign");
const aegis = @import("aegis");

const Args = struct {
    level: u8 = 0,
    name: []const u8 = "",
    tags: []const []const u8 = &.{},
    wait: aegis.units.Duration(.millisecond, u32) = .fromRaw(1500),
    jobs: aegis.int.Ranged(u8, 1, 64) = .literal(1),
    command: ?union(enum) { run: struct { fast: bool = false } } = null,
    pub const spec: ensign.Spec(@This()) = .{ .name = "free", .options = .{ .level = .{ .short = 'l', .global = true } } };
};

var heap: [1 << 16]u8 = undefined;
var out: [1 << 14]u8 = undefined;

/// Parses one argument; returns the level, or -1 for a mistake.
export fn ensignParse(arg: [*]const u8, arg_len: usize) i32 {
    var fixed: std.heap.FixedBufferAllocator = .init(&heap);
    const args = [_][]const u8{ arg[0..arg_len], "run", "--fast" };
    const outcome = ensign.parse(Args, fixed.allocator(), &args, .{}) catch return -1;
    return switch (outcome) {
        .parsed => |v| v.level,
        .help, .version, .complete => -2,
    };
}

/// Writes the help page and each completion script; returns the bytes of the last.
export fn ensignWrite(width: usize) isize {
    var w: std.Io.Writer = .fixed(&out);
    ensign.writeHelp(Args, &w, "free", width) catch return -1;
    for ([_]ensign.Shell{ .bash, .zsh, .fish, .powershell }) |shell| {
        w = .fixed(&out);
        ensign.writeCompletion(Args, shell, &w, "free") catch return -1;
    }
    return @intCast(w.buffered().len);
}
