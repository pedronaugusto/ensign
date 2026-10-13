//! The process's own arguments, environment and terminal.
const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parse.zig");
const model = @import("model.zig");
const help = @import("help.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Allocator = std.mem.Allocator;

/// What `parseArgs` can fail with: parsing, or decoding the arguments.
pub const ArgsError = parser.Error || std.process.Args.Iterator.InitError;

/// Where help wraps when the terminal says nothing, and the widest it wraps.
pub const default_width = 80;
pub const max_width = 100;

/// Parses the process's arguments into a `T`. The program's name is the
/// declaration's `name`, else the first argument's base name. On Windows
/// the arguments are decoded as std decodes them, to WTF-8, into `arena`,
/// and text values borrow them there; elsewhere they borrow the process's
/// own. Lists are allocated with `arena` too.
pub fn parseArgs(comptime T: type, arena: Allocator, args: std.process.Args, options: parser.Options) ArgsError!parser.Outcome(T) {
    // Never deinitialized: on Windows and WASI the values borrow the
    // iterator's buffer, which lives in `arena`.
    var it = try args.iterateAllocator(arena);
    var with = options;
    if (it.next()) |first| {
        if (with.name == null and model.declared(T).name == null) with.name = programName(first);
    }
    return parser.parseFrom(T, arena, &it, with);
}

/// The base name of a program's path, without `.exe` on Windows.
pub fn programName(path: []const u8) []const u8 {
    const windows = builtin.target.os.tag == .windows;
    const cut = if (windows) std.mem.findLastAny(u8, path, "/\\") else std.mem.findScalarLast(u8, path, '/');
    const base = if (cut) |c| path[c + 1 ..] else path;
    if (windows and base.len > 4 and std.ascii.eqlIgnoreCase(base[base.len - 4 ..], ".exe")) return base[0 .. base.len - 4];
    return if (base.len == 0) path else base;
}

/// Parses the process's arguments, or answers for the program: `--help`
/// and `--version` print to standard output and exit 0, and a mistake
/// prints its message and usage to standard error and exits 2. Help wraps
/// to the terminal, at most `max_width` columns. Lists and decoded arguments
/// live in the process's arena.
pub fn parseOrExit(comptime T: type, init: std.process.Init) T {
    var diagnostic: Diagnostic = .{};
    const outcome = parseArgs(T, init.arena.allocator(), init.minimal.args, .{
        .environ = init.environ_map,
        .diagnostic = &diagnostic,
    }) catch |err| switch (err) {
        error.OutOfMemory => std.process.fatal("out of memory reading the command line", .{}),
        else => {
            var buffer: [1024]u8 = undefined;
            var w = std.Io.File.stderr().writer(init.io, &buffer);
            const width = terminalWidth(init.io, .stderr(), init.environ_map) orelse default_width;
            diagnostic.write(&w.interface, @min(width, max_width)) catch std.process.exit(2);
            w.interface.flush() catch std.process.exit(2);
            std.process.exit(2);
        },
    };
    switch (outcome) {
        .parsed => |v| return v,
        .help => |h| {
            var buffer: [4096]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &buffer);
            const width = terminalWidth(init.io, .stdout(), init.environ_map) orelse default_width;
            h.write(&w.interface, @min(width, max_width)) catch std.process.exit(1);
            w.interface.flush() catch std.process.exit(1);
            std.process.exit(0);
        },
        .version => |v| {
            var buffer: [256]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &buffer);
            v.write(&w.interface) catch std.process.exit(1);
            w.interface.flush() catch std.process.exit(1);
            std.process.exit(0);
        },
    }
}

/// The columns of the terminal `file` writes to: `COLUMNS` when the
/// environment sets it, else what the terminal reports. Null when `file`
/// is no terminal.
pub fn terminalWidth(io: std.Io, file: std.Io.File, environ: ?*const std.process.Environ.Map) ?u16 {
    if (environ) |map| if (map.get("COLUMNS")) |columns| {
        if (std.fmt.parseInt(u16, columns, 10)) |n| {
            if (n > 0) return n;
        } else |_| {}
    };
    const tty = file.isTty(io) catch return null;
    if (!tty) return null;
    if (builtin.target.os.tag == .windows) {
        var get = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        const status = get.operate(io, file) catch return null;
        if (status != .SUCCESS or get.Data.dwWindowSize.X <= 0) return null;
        return @intCast(get.Data.dwWindowSize.X);
    } else if (@hasDecl(std.posix, "T") and @hasDecl(std.posix.T, "IOCGWINSZ")) {
        var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const result = io.operate(.{ .device_io_control = .{ .file = file, .code = std.posix.T.IOCGWINSZ, .arg = &size } }) catch return null;
        if (result.device_io_control < 0 or size.col == 0) return null;
        return size.col;
    } else return null;
}

test "program names" {
    try std.testing.expectEqualStrings("app", programName("/usr/bin/app"));
    try std.testing.expectEqualStrings("app", programName("app"));
    if (builtin.target.os.tag == .windows) try std.testing.expectEqualStrings("app", programName("C:\\bin\\app.EXE"));
}
