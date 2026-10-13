//! The process's own arguments, as `std.process.Args` holds them on each
//! system: bytes on POSIX, WTF-16 decoded to WTF-8 on Windows.
const std = @import("std");
const builtin = @import("builtin");
const ensign = @import("../ensign.zig");

const T = struct {
    name: []const u8 = "",
    count: u8 = 0,
    rest: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .count = .{ .short = 'c' }, .rest = .{ .positional = true } } };
};

fn args(comptime ascii: []const u8, comptime tail: []const u16) std.process.Args {
    if (builtin.target.os.tag == .windows) {
        const line = comptime std.unicode.utf8ToUtf16LeStringLiteral(ascii) ++ tail;
        return .{ .vector = line };
    }
    var words = std.mem.tokenizeScalar(u8, ascii, ' ');
    const S = struct {
        var vector: [8][*:0]const u8 = undefined;
        var storage: [8][64:0]u8 = undefined;
    };
    var n: usize = 0;
    while (words.next()) |word| : (n += 1) {
        @memcpy(S.storage[n][0..word.len], word);
        S.storage[n][word.len] = 0;
        S.vector[n] = S.storage[n][0..word.len :0];
    }
    return .{ .vector = S.vector[0..n] };
}

test "the process's arguments, with the program's name taken from the first" {
    if (builtin.target.os.tag == .wasi or builtin.target.os.tag == .freestanding) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try ensign.parseArgs(T, arena.allocator(), args("/usr/local/bin/tool --name=x -c 7 a b", &.{}), .{});
    const v = outcome.parsed;
    try std.testing.expectEqualStrings("x", v.name);
    try std.testing.expectEqual(@as(u8, 7), v.count);
    try std.testing.expectEqual(@as(usize, 2), v.rest.len);
    var diagnostic: ensign.Diagnostic = .{};
    try std.testing.expectError(error.UnknownOption, ensign.parseArgs(T, arena.allocator(), args("/usr/local/bin/tool --nmae", &.{}), .{ .diagnostic = &diagnostic }));
    try std.testing.expectEqualStrings("tool", diagnostic.program);
}

test "arguments that are not UTF-8 reach the value as std decodes them" {
    if (builtin.target.os.tag == .wasi or builtin.target.os.tag == .freestanding) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    if (builtin.target.os.tag == .windows) {
        // An unpaired surrogate is WTF-8 after decoding: ED A0 80.
        const outcome = try ensign.parseArgs(T, arena.allocator(), args("tool --name=", &.{0xD800}), .{});
        try std.testing.expectEqualStrings("\xed\xa0\x80", outcome.parsed.name);
    } else {
        const raw: [*:0]const u8 = "--name=\xff\xfe";
        var vector = [_][*:0]const u8{ "tool", raw };
        const outcome = try ensign.parseArgs(T, arena.allocator(), .{ .vector = &vector }, .{});
        try std.testing.expectEqualStrings("\xff\xfe", outcome.parsed.name);
    }
}
