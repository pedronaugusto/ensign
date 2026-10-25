//! What went wrong on a command line, in words a person can act on.
const std = @import("std");
const text = @import("text.zig");
const Writer = std.Io.Writer;

/// A command the parser read: its place below the program, and its usage
/// and help, which the declaration generates.
pub const Page = struct {
    /// The subcommand names below the program, space-separated; empty at the root.
    path: []const u8,
    /// The help flag's long name, when the command answers one.
    help_flag: ?[]const u8,
    writeUsage: *const fn (w: *Writer, program: []const u8, width: usize) Writer.Error!void,
    writeHelp: *const fn (w: *Writer, program: []const u8, width: usize) Writer.Error!void,

    /// `program` and the path, as the command line spells the command.
    pub fn writeName(p: *const Page, w: *Writer, program: []const u8) Writer.Error!void {
        try text.writeEscaped(w, program);
        if (p.path.len != 0) try w.print(" {s}", .{p.path});
    }
};

/// The kinds of mistake, one for each error the parser returns.
pub const Problem = enum {
    unknown_option,
    unknown_command,
    unexpected_argument,
    missing_value,
    unexpected_value,
    invalid_value,
    missing_option,
    missing_argument,
    missing_command,
    conflict,
    /// An option given needs another that was not.
    required_by,
    /// None of a required group's options was given.
    missing_one,
};

/// Filled by the parser when it returns an error other than
/// `OutOfMemory`. Every slice borrows from the arguments, the environment
/// or the declaration.
pub const Diagnostic = struct {
    problem: Problem = .unexpected_argument,
    /// The command whose arguments were being read.
    page: ?*const Page = null,
    program: []const u8 = "",
    /// What the command line held: the unknown option or argument, or the
    /// option as it was written.
    argument: []const u8 = "",
    /// The option or positional, as help spells it: `--jobs`, `<FILE>`.
    option: []const u8 = "",
    /// The value that did not parse.
    value: []const u8 = "",
    /// What the value had to be, or the commands there are.
    expected: []const u8 = "",
    /// The closest known name to an unknown one.
    suggestion: ?[]const u8 = null,
    /// The option the conflicting one was given with, or the one that
    /// needs a missing option.
    other: []const u8 = "",
    /// The variable a bad value came from, or one that could give a
    /// missing option.
    env: ?[]const u8 = null,

    /// One line saying what is wrong, without a newline.
    pub fn writeMessage(d: Diagnostic, w: *Writer) Writer.Error!void {
        if (d.page) |p| try p.writeName(w, d.program) else try text.writeEscaped(w, d.program);
        try w.writeAll(": ");
        switch (d.problem) {
            .unknown_option => try quoted(w, "unknown option ", d.argument),
            .unknown_command => try quoted(w, "unknown command ", d.argument),
            .unexpected_argument => try quoted(w, "unexpected argument ", d.argument),
            .missing_value => try w.print("'{s}' needs a value: {s}", .{ d.option, d.expected }),
            .unexpected_value => {
                try w.print("'{s}' takes no value, but was given ", .{d.option});
                try quoted(w, "", d.value);
            },
            .invalid_value => {
                try quoted(w, "invalid value ", d.value);
                if (d.env) |name| {
                    try w.writeAll(" in ");
                    try text.writeEscaped(w, name);
                }
                try w.print(" for '{s}': expected {s}", .{ d.option, d.expected });
            },
            .missing_option => {
                try w.print("missing option '{s}'", .{d.option});
                if (d.env) |name| try w.print(" (or set {s})", .{name});
            },
            .missing_argument => try w.print("missing argument {s}", .{d.option}),
            .missing_command => try w.print("missing command: expected {s}", .{d.expected}),
            .conflict => try w.print("'{s}' cannot be used with '{s}'", .{ d.option, d.other }),
            .required_by => {
                try w.print("'{s}' needs '{s}'", .{ d.other, d.option });
                if (d.env) |name| try w.print(" (or set {s})", .{name});
            },
            .missing_one => try w.print("missing one of {s}", .{d.expected}),
        }
        if (d.suggestion) |s| try w.print("; did you mean '{s}'?", .{s});
    }

    /// The message, the command's usage and where to find more, each line ended.
    pub fn write(d: Diagnostic, w: *Writer, width: usize) Writer.Error!void {
        try d.writeMessage(w);
        try w.writeByte('\n');
        const p = d.page orelse return;
        try p.writeUsage(w, d.program, width);
        if (p.help_flag) |flag| {
            try w.writeAll("Try '");
            try p.writeName(w, d.program);
            try w.print(" --{s}' for more information.\n", .{flag});
        }
    }
};

fn quoted(w: *Writer, prefix: []const u8, bytes: []const u8) Writer.Error!void {
    try w.writeAll(prefix);
    try w.writeByte('\'');
    try text.writeEscaped(w, bytes);
    try w.writeByte('\'');
}

test "messages" {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const d: Diagnostic = .{ .problem = .invalid_value, .program = "app", .value = "x\xff", .option = "--jobs", .expected = "an integer from 0 to 255", .env = "APP_JOBS" };
    try d.writeMessage(&w);
    try std.testing.expectEqualStrings("app: invalid value 'x\\xff' in APP_JOBS for '--jobs': expected an integer from 0 to 255", w.buffered());
}
