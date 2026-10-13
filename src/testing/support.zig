//! Parsing in tests: a value, or the error and the message a person reads.
const std = @import("std");
const ensign = @import("../ensign.zig");

/// The value `args` parse to; release it with `ensign.free`.
pub fn parsed(comptime T: type, args: []const []const u8) !T {
    return parsedWith(T, args, .{});
}

pub fn parsedWith(comptime T: type, args: []const []const u8, options: ensign.Options) !T {
    return switch (try ensign.parse(T, std.testing.allocator, args, options)) {
        .parsed => |v| v,
        .help, .version => error.TestUnexpectedResult,
    };
}

/// That `args` fail with `err`, and the one-line message reads `message`.
pub fn fails(comptime T: type, args: []const []const u8, err: ensign.Error, message: []const u8) !void {
    return failsWith(T, args, .{}, err, message);
}

pub fn failsWith(comptime T: type, args: []const []const u8, options: ensign.Options, err: ensign.Error, message: []const u8) !void {
    var diagnostic: ensign.Diagnostic = .{};
    var with = options;
    with.diagnostic = &diagnostic;
    if (ensign.parse(T, std.testing.allocator, args, with)) |outcome| {
        if (outcome == .parsed) ensign.free(T, std.testing.allocator, &outcome.parsed);
        std.debug.print("parsed, expected {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    } else |got| try std.testing.expectEqual(err, got);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try diagnostic.writeMessage(&w);
    try std.testing.expectEqualStrings(message, w.buffered());
}

/// The help page `args` ask for, at `width` columns.
pub fn helpPage(comptime T: type, args: []const []const u8, width: usize, out: []u8) ![]const u8 {
    const outcome = try ensign.parse(T, std.testing.allocator, args, .{});
    var w: std.Io.Writer = .fixed(out);
    switch (outcome) {
        .help => |h| try h.write(&w, width),
        else => return error.TestUnexpectedResult,
    }
    return w.buffered();
}

/// An environment of `pairs`, for options that read one.
pub fn environ(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}
