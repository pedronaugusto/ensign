//! Completion scripts for bash, zsh, fish and PowerShell, generated from
//! the declaration. Each script holds the whole command tree: it finds the
//! subcommand the line is in, skipping options and their values as the
//! parser does, then offers that command's options, subcommands, enum
//! values, or paths where the declaration hints at them.
const std = @import("std");
const tree = @import("complete/tree.zig");
const bash = @import("complete/bash.zig");
const zsh = @import("complete/zsh.zig");
const fish = @import("complete/fish.zig");
const powershell = @import("complete/powershell.zig");
const Writer = std.Io.Writer;

pub const Shell = enum { bash, zsh, fish, powershell };

pub const CompletionError = Writer.Error || error{
    /// The program's name holds a byte the scripts cannot carry: only
    /// letters, digits, `-`, `_`, `.` and `+` are allowed.
    InvalidName,
};

/// Writes the completion script for `shell` of the program `name`, whose
/// arguments are `T`. bash and zsh source it, or zsh loads it from `fpath`
/// as `_<name>`; fish loads it from `completions/<name>.fish`; PowerShell
/// dot-sources it from a profile.
pub fn writeCompletion(comptime T: type, shell: Shell, w: *Writer, name: []const u8) CompletionError!void {
    if (!tree.validName(name)) return error.InvalidName;
    const nodes = comptime tree.nodes(T);
    switch (shell) {
        .bash => try bash.write(nodes, w, name),
        .zsh => try zsh.write(nodes, w, name),
        .fish => try fish.write(nodes, w, name),
        .powershell => try powershell.write(nodes, w, name),
    }
}

test {
    _ = tree;
}
