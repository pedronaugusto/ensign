//! The process's own arguments, environment and terminal.
const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parse.zig");
const model = @import("model.zig");
const help = @import("help.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const completer = @import("completer.zig");
const tree = @import("complete/tree.zig");
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
/// own. Lists are allocated with `arena` too. When the environment holds
/// `ENSIGN_COMPLETE`, a completion script is asking: the arguments are the
/// words typed, and the outcome is `.complete`.
pub fn parseArgs(comptime T: type, arena: Allocator, args: std.process.Args, options: parser.Options) ArgsError!parser.Outcome(T) {
    // Never deinitialized: on Windows and WASI the values borrow the
    // iterator's buffer, which lives in `arena`.
    var it = try args.iterateAllocator(arena);
    var with = options;
    if (it.next()) |first| {
        if (with.name == null and model.declared(T).name == null) with.name = programName(first);
    }
    if (options.environ) |environ| if (environ.get(completer.variable)) |asked| {
        var words: std.ArrayList([]const u8) = .empty;
        while (it.next()) |arg| try words.append(arena, arg);
        return .{ .complete = request(T, asked, words.items) };
    };
    return parser.parseFrom(T, arena, &it, with);
}

/// The request in `asked`, `<protocol>:<key>`, with `words` the arguments
/// after the program's name: the words before the cursor, then the one
/// being completed.
pub fn request(comptime T: type, asked: []const u8, words: []const []const u8) completer.Request {
    const prefix = if (words.len == 0) "" else words[words.len - 1];
    const before = if (words.len == 0) words else words[0 .. words.len - 1];
    const colon = std.mem.findScalar(u8, asked, ':') orelse asked.len;
    const version = std.fmt.parseInt(u32, asked[0..colon], 10) catch 0;
    if (version != completer.protocol or colon == asked.len)
        return .{ .key = "", .args = before, .prefix = prefix, .completer = null, .problem = "the completion script speaks another protocol than this program's 1; regenerate it" };
    const key = asked[colon + 1 ..];
    const answers = comptime tree.answers(T);
    const found = tree.answering(answers, key);
    return .{ .key = key, .args = before, .prefix = prefix, .completer = found, .problem = if (found == null) "nothing here completes by the program" else "" };
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
/// and `--version` print to standard output and exit 0, a completion
/// script's request is answered there too (1 and a message on standard error
/// when the completer fails), and a mistake
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
            var w = stderr(init.io, &buffer);
            const width = (terminalWidth(init.io, .stderr(), init.environ_map) catch std.process.exit(2)) orelse default_width;
            diagnostic.write(&w.interface, @min(width, max_width)) catch std.process.exit(2);
            w.interface.flush() catch std.process.exit(2);
            std.process.exit(2);
        },
    };
    switch (outcome) {
        .parsed => |v| return v,
        .help => |h| {
            var buffer: [4096]u8 = undefined;
            var w = stdout(init.io, &buffer);
            const width = (terminalWidth(init.io, .stdout(), init.environ_map) catch std.process.exit(1)) orelse default_width;
            h.write(&w.interface, @min(width, max_width)) catch std.process.exit(1);
            w.interface.flush() catch std.process.exit(1);
            std.process.exit(0);
        },
        .version => |v| {
            var buffer: [256]u8 = undefined;
            var w = stdout(init.io, &buffer);
            v.write(&w.interface) catch std.process.exit(1);
            w.interface.flush() catch std.process.exit(1);
            std.process.exit(0);
        },
        .complete => |r| {
            var buffer: [4096]u8 = undefined;
            var w = stdout(init.io, &buffer);
            var c = r.completion(init.io, init.arena.allocator(), init.environ_map, &w.interface);
            r.answer(&c) catch |err| switch (err) {
                error.WriteFailed => std.process.exit(1),
                // The scripts discard standard error; a person running the line by hand reads it.
                error.Failed => std.process.fatal("completion failed: {s}", .{c.failure}),
            };
            w.interface.flush() catch std.process.exit(1);
            std.process.exit(0);
        },
    }
}

/// Standard output, written as the stream it is: each write goes where the
/// file stands, after what came before it, so output the shell appends
/// (`>> log`) is appended, and output that shares a file with standard error
/// (`> log 2>&1`) follows it in order. std's `File.writer` writes a regular
/// file at a position of its own, from 0: it overwrote what the file held
/// and what the other stream wrote. Every write ensign makes goes through
/// these two, and a program on ensign writes through them.
pub fn stdout(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return stream(io, .stdout(), buffer);
}

/// Standard error, written as a stream: see `stdout`.
pub fn stderr(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return stream(io, .stderr(), buffer);
}

fn stream(io: std.Io, file: std.Io.File, buffer: []u8) std.Io.File.Writer {
    return .initStreaming(file, io, buffer);
}

/// The columns of the terminal `file` writes to: `COLUMNS` when the
/// environment sets it, else what the terminal reports. Null when `file`
/// is no terminal. A cancel that lands while the terminal is asked is
/// `Canceled`, never taken for no terminal.
pub fn terminalWidth(io: std.Io, file: std.Io.File, environ: ?*const std.process.Environ.Map) std.Io.Cancelable!?u16 {
    if (environ) |map| if (map.get("COLUMNS")) |columns| {
        // glint-ignore: Z026 -- a COLUMNS that is no width is not taken: the terminal is asked below
        if (std.fmt.parseInt(u16, columns, 10)) |n| {
            if (n > 0) return n;
        } else |_| {}
    };
    const tty = try file.isTty(io);
    if (!tty) return null;
    if (builtin.target.os.tag == .windows) {
        // glint-ignore: P007 -- the console's width: std reads it on Windows only through this request, as POSIX's through IOCGWINSZ below
        var get = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        const status = try get.operate(io, file);
        if (status != .SUCCESS or get.Data.dwWindowSize.X <= 0) return null;
        return @intCast(get.Data.dwWindowSize.X);
    } else if (@hasDecl(std.posix, "T") and @hasDecl(std.posix.T, "IOCGWINSZ")) {
        var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const result = try io.operate(.{ .device_io_control = .{ .file = file, .code = std.posix.T.IOCGWINSZ, .arg = &size } });
        if (result.device_io_control < 0 or size.col == 0) return null;
        return size.col;
    } else return null;
}

test "a cancel while the terminal is asked for its width is Canceled, not no terminal" {
    const Canceling = struct {
        var vtable: std.Io.VTable = undefined;
        fn isTty(_: ?*anyopaque, _: std.Io.File) std.Io.Cancelable!bool {
            return error.Canceled;
        }
    };
    Canceling.vtable = std.testing.io.vtable.*;
    Canceling.vtable.fileIsTty = Canceling.isTty;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &Canceling.vtable };
    try std.testing.expectError(error.Canceled, terminalWidth(io, .stdout(), null));
}

test "program names" {
    try std.testing.expectEqualStrings("app", programName("/usr/bin/app"));
    try std.testing.expectEqualStrings("app", programName("app"));
    if (builtin.target.os.tag == .windows) try std.testing.expectEqualStrings("app", programName("C:\\bin\\app.EXE"));
}

test "what a stream writes to a file opened to append follows what the file held" {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi or builtin.target.os.tag == .freestanding) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "log", .data = "first\n" });
    // as the shell opens it for `>> log`
    const fd = try std.posix.openat(tmp.dir.handle, "log", .{ .ACCMODE = .WRONLY, .APPEND = true }, 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var buffer: [16]u8 = undefined;
    var w = stream(io, file, &buffer);
    try w.interface.writeAll("second\n");
    try w.interface.flush();
    file.close(io);
    var read: [64]u8 = undefined;
    try std.testing.expectEqualStrings("first\nsecond\n", try tmp.dir.readFile(io, "log", &read));
}

test "two streams sharing a file write in the order they flush, neither over the other" {
    if (builtin.target.os.tag == .wasi or builtin.target.os.tag == .freestanding) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // as the shell gives standard output and standard error one file for `> log 2>&1`
    const file = try tmp.dir.createFile(io, "log", .{});
    var out_buffer: [16]u8 = undefined;
    var err_buffer: [16]u8 = undefined;
    var out = stream(io, file, &out_buffer);
    var err = stream(io, file, &err_buffer);
    try out.interface.writeAll("a line\n");
    try out.interface.flush();
    try err.interface.writeAll("a warning\n");
    try err.interface.flush();
    try out.interface.writeAll("the end\n");
    try out.interface.flush();
    file.close(io);
    var read: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a line\na warning\nthe end\n", try tmp.dir.readFile(io, "log", &read));
}
