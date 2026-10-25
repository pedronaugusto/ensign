//! Command-line arguments parsed into a Zig type the program declares: the
//! parser, help and shell completions are generated from the declaration at
//! compile time.
const std = @import("std");
const spec = @import("spec.zig");
const parser = @import("parse.zig");
const diagnostic = @import("diagnostic.zig");
const help = @import("help.zig");
const completion = @import("complete.zig");
const process = @import("process.zig");
const rendering = @import("render.zig");
const completer = @import("completer.zig");

pub const Spec = spec.Spec;
pub const Option = spec.Option;
pub const Command = spec.Command;
pub const Example = spec.Example;
pub const Section = spec.Section;
pub const Flag = spec.Flag;
pub const Hint = spec.Hint;
pub const External = spec.External;

pub const Error = parser.Error;
pub const Options = parser.Options;
pub const Outcome = parser.Outcome;
pub const Help = parser.Help;
pub const Version = parser.Version;
pub const Diagnostic = diagnostic.Diagnostic;
pub const Problem = diagnostic.Problem;
pub const free = parser.free;
pub const ArgsError = process.ArgsError;
pub const parseArgs = process.parseArgs;
pub const parseOrExit = process.parseOrExit;
pub const terminalWidth = process.terminalWidth;
pub const render = rendering.render;
pub const RenderError = rendering.RenderError;
pub const Shell = completion.Shell;
pub const CompletionError = completion.CompletionError;
pub const writeCompletion = completion.writeCompletion;
pub const Completion = completer.Completion;
pub const Completer = completer.Completer;
pub const CompletionRequest = completer.Request;
pub const completionRequest = process.request;

/// Parses `args`, the arguments after the program's name, into a `T`.
/// Text values borrow from `args` and the environment; lists are allocated
/// with `gpa`, and `free` releases them.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, args: []const []const u8, options: Options) Error!Outcome(T) {
    var cursor: parser.Slice = .{ .args = args };
    return parser.parseFrom(T, gpa, &cursor, options);
}

/// Writes the help of `T`'s root command.
pub fn writeHelp(comptime T: type, w: *std.Io.Writer, program: []const u8, width: usize) std.Io.Writer.Error!void {
    return help.Pages(&.{T}, &.{}).page.writeHelp(w, program, width);
}

test {
    _ = spec;
    _ = parser;
    _ = diagnostic;
    _ = help;
    _ = process;
    _ = rendering;
    _ = completion;
    _ = @import("model.zig");
    _ = @import("text.zig");
    _ = @import("lookup.zig");
    _ = @import("value.zig");
    _ = @import("kinds.zig");
    _ = completer;
}
