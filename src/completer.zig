//! Completions the program answers itself: a completer a field or its type
//! declares, and the request a completion script makes of the program. The
//! script runs the command as typed with `ENSIGN_COMPLETE=1:<key>` in its
//! environment, the words before the cursor, then the word being completed,
//! as its arguments; the program prints one candidate a line, `value` or
//! `value<TAB>description`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The variable a completion script sets when it asks the program.
pub const variable = "ENSIGN_COMPLETE";

/// The version of the request and answer, the first field of the variable.
pub const protocol = 1;

/// Answers a completion of one option's value or one positional.
pub const Completer = *const fn (c: *Completion) Completion.Error!void;

/// One completion the program answers: what has been typed, and where the
/// candidates go.
pub const Completion = struct {
    /// The word being completed, as typed so far; after `=` for `--name=`.
    prefix: []const u8,
    /// The whole words before it, after the program's name, as the shell
    /// holds them: quotes a shell keeps are kept.
    args: []const []const u8,
    io: std.Io,
    gpa: Allocator,
    environ: ?*const std.process.Environ.Map,
    out: *Writer,
    /// Why the completer could not answer, when it returned `error.Failed`.
    failure: []const u8 = "",

    pub const Error = error{
        /// The candidates could not be written.
        WriteFailed,
        /// The completer could not answer; `failure` says why.
        Failed,
    };

    /// Offers `value`, with a one-line description shells that show one show
    /// (zsh, fish, PowerShell). A value holding a tab or a line break cannot
    /// be offered, and fails the completion.
    pub fn add(c: *Completion, value: []const u8, description: []const u8) Error!void {
        if (std.mem.findAny(u8, value, "\t\r\n") != null) return c.fail("a candidate holds a tab or a line break, which the answer cannot carry");
        try c.out.writeAll(value);
        if (description.len != 0) {
            try c.out.writeByte('\t');
            const line = description[0 .. std.mem.findAny(u8, description, "\r\n") orelse description.len];
            for (line) |b| try c.out.writeByte(if (b == '\t') ' ' else b);
        }
        try c.out.writeByte('\n');
    }

    /// Records why the completion failed; return what it returns.
    pub fn fail(c: *Completion, message: []const u8) error{Failed} {
        c.failure = message;
        return error.Failed;
    }
};

/// A request a completion script made: what to complete, and the completer
/// the declaration names for it.
pub const Request = struct {
    /// `path:spelling` or `path:#index`, as the script names it.
    key: []const u8,
    args: []const []const u8,
    prefix: []const u8,
    /// Null when the declaration names no completer for `key`, or the
    /// script speaks another protocol; `problem` says which.
    completer: ?Completer,
    problem: []const u8 = "",

    /// Runs the completer into `c`, which holds the request's prefix and args.
    pub fn answer(r: Request, c: *Completion) Completion.Error!void {
        const completer = r.completer orelse return c.fail(r.problem);
        return completer(c);
    }

    /// The completion this request answers into `out`.
    pub fn completion(r: Request, io: std.Io, gpa: Allocator, environ: ?*const std.process.Environ.Map, out: *Writer) Completion {
        return .{ .prefix = r.prefix, .args = r.args, .io = io, .gpa = gpa, .environ = environ, .out = out };
    }
};

test "candidates are written one a line, with their description" {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    var c: Completion = .{ .prefix = "", .args = &.{}, .io = std.testing.io, .gpa = std.testing.allocator, .environ = null, .out = &w };
    try c.add("main", "The main\tbranch\nand more");
    try c.add("next", "");
    try std.testing.expectEqualStrings("main\tThe main branch\nnext\n", w.buffered());
    try std.testing.expectError(error.Failed, c.add("a\tb", ""));
    try std.testing.expect(c.failure.len != 0);
}
