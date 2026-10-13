//! Memory: parsing allocates only the lists a value holds, survives every
//! allocation failure without a leak, and help, errors and completions
//! allocate nothing.
const std = @import("std");
const ensign = @import("../ensign.zig");
const shake = @import("shakedown");

const Scalars = struct {
    level: u32 = 0,
    name: []const u8 = "",
    mode: enum { a, b } = .a,
    fast: bool = false,
    verbose: u8 = 0,
    command: ?union(enum) { run: struct { force: bool = false, file: ?[]const u8 = null } } = null,
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .verbose = .{ .short = 'v', .count = true, .global = true } } };
};

const Lists = struct {
    tags: []const []const u8 = &.{"default"},
    sizes: []const u32 = &.{},
    files: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .sizes = .{ .delimiter = ',', .env = "SIZES" },
        .files = .{ .positional = true },
    } };
};

test "a value without lists is parsed with no allocation" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const outcome = try ensign.parse(Scalars, failing.allocator(), &.{ "--level=3", "--name", "x", "--mode=b", "--fast", "run", "-vv", "--force", "--file=f" }, .{});
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(u8, 2), outcome.parsed.verbose);
    // Mistakes, their messages and help allocate nothing either.
    var diagnostic: ensign.Diagnostic = .{};
    try std.testing.expectError(error.UnknownOption, ensign.parse(Scalars, failing.allocator(), &.{"--levle"}, .{ .diagnostic = &diagnostic }));
    var buffer: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try diagnostic.write(&w, 80);
    const help = try ensign.parse(Scalars, failing.allocator(), &.{ "run", "--help" }, .{});
    try help.help.write(&w, 80);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "the lists a value holds are all it keeps" {
    var counting: shake.alloc.Counting = .init(std.testing.allocator);
    const gpa = counting.allocator();
    const outcome = try ensign.parse(Lists, gpa, &.{ "--tags=a", "--sizes=1,2,3", "x", "--tags", "b", "y", "z" }, .{});
    const v = outcome.parsed;
    const kept = 2 * @sizeOf([]const u8) + 3 * @sizeOf(u32) + 3 * @sizeOf([]const u8);
    try std.testing.expectEqual(@as(usize, kept), counting.live_bytes);
    ensign.free(Lists, gpa, &v);
    try std.testing.expectEqual(@as(usize, 0), counting.live_bytes);
}

fn parseLists(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !void {
    const outcome = try ensign.parse(Lists, gpa, &.{ "--tags=a", "--tags=b", "x", "y" }, .{ .environ = environ });
    ensign.free(Lists, gpa, &outcome.parsed);
}

test "every allocation failure is survived without a leak" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("SIZES", "4,5,6");
    var backing: shake.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(backing.allocator(), parseLists, .{@as(*const std.process.Environ.Map, &environ)});
}

fn failLate(gpa: std.mem.Allocator) !void {
    // Lists are built, then a required argument is found missing: what was
    // built is released.
    const Late = struct {
        tags: []const []const u8 = &.{},
        command: union(enum) { run: struct {
            names: []const []const u8 = &.{},
            needed: []const u8,
            pub const spec: ensign.Spec(@This()) = .{ .options = .{ .needed = .{ .positional = true } } };
        } },
        pub const spec: ensign.Spec(@This()) = .{ .options = .{ .tags = .{ .global = true } } };
    };
    if (ensign.parse(Late, gpa, &.{ "--tags=a", "run", "--names=n", "--tags=b" }, .{})) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.MissingArgument => {},
        else => return err,
    }
}

test "a failure after lists were built releases them" {
    var backing: shake.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(backing.allocator(), failLate, .{});
}

test "help asked after lists were built releases them" {
    const outcome = try ensign.parse(Lists, std.testing.allocator, &.{ "--tags=a", "x", "--help" }, .{});
    try std.testing.expect(outcome == .help);
}
