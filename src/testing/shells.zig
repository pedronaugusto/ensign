//! Runs a completion script in a real shell, in a scratch directory that is
//! also the shell's home: no profile, rc file or user configuration is read.
const std = @import("std");
const builtin = @import("builtin");
const ensign = @import("../ensign.zig");

/// One completion: the line up to the cursor (a trailing space completes
/// a new word), and the candidates, sorted bytewise and space-separated.
pub const Case = struct {
    line: []const u8,
    want: []const u8,
    /// What this shell offers instead, where it differs on its own terms.
    fish: ?[]const u8 = null,
    /// The one shell the case is for, when the others see the line otherwise.
    only: ?Shell = null,
};

pub const Shell = ensign.Shell;

/// The executable that runs each shell's script.
pub fn executable(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => "bash",
        .zsh => "zsh",
        .fish => "fish",
        .powershell => "pwsh",
    };
}

/// Whether `shell` must be present: bash on Linux, where CI always has it.
pub fn required(shell: Shell) bool {
    return shell == .bash and builtin.target.os.tag == .linux;
}

/// Writes the script for `T` and a driver for `cases` into a scratch
/// directory holding `alpha.txt`, `beta.zig` and `sub/`, runs the shell
/// there, and checks each case's candidates. Skips when the shell is not
/// installed, unless it is required.
pub fn check(comptime T: type, shell: Shell, name: []const u8, cases: []const Case) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (builtin.target.os.tag == .windows and shell != .powershell) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.zig", .data = "" });
    try tmp.dir.createDir(io, "sub", .default_dir);

    var script: std.Io.Writer.Allocating = .init(gpa);
    defer script.deinit();
    try ensign.writeCompletion(T, shell, &script.writer, name);
    try tmp.dir.writeFile(io, .{ .sub_path = if (shell == .powershell) "script.ps1" else "script", .data = script.written() });

    var driver: std.Io.Writer.Allocating = .init(gpa);
    defer driver.deinit();
    try writeDriver(&driver.writer, shell, name, cases);
    try tmp.dir.writeFile(io, .{ .sub_path = if (shell == .powershell) "driver.ps1" else "driver", .data = driver.written() });

    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);
    var environ = try std.testing.environ.createMap(gpa);
    defer environ.deinit();
    for ([_][]const u8{ "HOME", "USERPROFILE", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "ZDOTDIR" }) |key| try environ.put(key, home);
    for ([_][]const u8{ "BASH_ENV", "ENV", "PSModulePath" }) |key| _ = environ.swapRemove(key);
    try environ.put("LC_ALL", "C");
    try environ.put("TERM", "dumb");

    const argv: []const []const u8 = switch (shell) {
        .bash => &.{ "bash", "--norc", "--noprofile", "driver" },
        .zsh => &.{ "zsh", "-f", "driver" },
        .fish => &.{ "fish", "--no-config", "driver" },
        .powershell => &.{ "pwsh", "-NoProfile", "-NonInteractive", "-File", "driver.ps1" },
    };
    const result = std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = home }, .environ_map = &environ }) catch |err| switch (err) {
        error.FileNotFound => {
            if (required(shell)) {
                std.debug.print("{s} is required on this system and was not found\n", .{executable(shell)});
                return err;
            }
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0 or result.stderr.len != 0) {
        std.debug.print("{s} failed ({any}):\n{s}\n", .{ executable(shell), result.term, result.stderr });
        return error.ShellFailed;
    }
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, result.stdout, "\r\n"), '\n');
    for (cases) |case| {
        if (case.only) |only| if (only != shell) continue;
        const got = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
        const want = if (shell == .fish) case.fish orelse case.want else case.want;
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("{s}: completing '{s}'\n  want: '{s}'\n  got:  '{s}'\n", .{ executable(shell), case.line, want, got });
            return error.TestUnexpectedResult;
        }
    }
}

fn writeDriver(w: *std.Io.Writer, shell: Shell, name: []const u8, cases: []const Case) !void {
    switch (shell) {
        .bash => {
            try w.print(
                \\source ./script
                \\t() {{ COMP_WORDS=("$@"); COMP_CWORD=$(( ${{#COMP_WORDS[@]}} - 1 )); COMPREPLY=(); _ensign_{s}; printf '%s\n' "${{COMPREPLY[@]}}" | sort | paste -sd' ' -; }}
                \\
            , .{name});
            for (cases) |case| if (case.only == null or case.only == shell) try words(w, "t", case.line, '\'');
        },
        .zsh => {
            try w.print(
                \\compdef() {{ : }}
                \\_describe() {{ local item; for item in "${{(@P)4}}"; do item=${{item%%:*}}; [[ $item == ${{ensign_cur}}* ]] && ensign_out+=("$item"); done }}
                \\compadd() {{ [[ $1 == -- ]] && shift; local v; for v in "$@"; do [[ $v == ${{ensign_cur}}* ]] && ensign_out+=("$ensign_iprefix$v"); done }}
                \\_files() {{ local f; for f in ${{ensign_cur}}*(N); do [[ $1 == -/ && ! -d $f ]] && continue; ensign_out+=("$f"); done }}
                \\_command_names() {{ [[ -n $PATH ]] && ensign_out+=('<commands>') }}
                \\compset() {{ if [[ $1 == -P ]]; then ensign_iprefix="${{ensign_cur%%=*}}="; ensign_cur="${{ensign_cur#*=}}"; fi }}
                \\source ./script
                \\t() {{ words=("$@"); CURRENT=$#words; ensign_cur="${{words[CURRENT]}}"; ensign_iprefix=; ensign_out=(); _ensign_{s}; print -r -- "${{(j: :)${{(@o)ensign_out}}}}" }}
                \\
            , .{name});
            for (cases) |case| if (case.only == null or case.only == shell) try words(w, "t", case.line, '\'');
        },
        .fish => {
            try w.print(
                \\source ./script
                \\function {s}; end
                \\function t
                \\    set -l out (complete -C"$argv[1]" | string replace -r '\t.*' '' | sort)
                \\    echo (string join ' ' -- $out)
                \\end
                \\
            , .{name});
            for (cases) |case| if (case.only == null or case.only == shell) {
                try w.writeAll("t '");
                try w.writeAll(case.line);
                try w.writeAll("'\n");
            };
        },
        .powershell => {
            try w.writeAll(
                \\. ./script.ps1
                \\function t([string]$line) {
                \\    $r = TabExpansion2 -inputScript $line -cursorColumn $line.Length
                \\    $m = [string[]]@($r.CompletionMatches | ForEach-Object { $_.CompletionText })
                \\    [Array]::Sort($m, [StringComparer]::Ordinal)
                \\    $m -join ' '
                \\}
                \\
            );
            for (cases) |case| if (case.only == null or case.only == shell) {
                try w.writeAll("t '");
                try w.writeAll(case.line);
                try w.writeAll("'\n");
            };
        },
    }
}

/// `t 'w1' 'w2' ''`: the line's words, a trailing space making an empty last word.
fn words(w: *std.Io.Writer, function: []const u8, line: []const u8, quote: u8) !void {
    try w.writeAll(function);
    var parts = std.mem.splitScalar(u8, line, ' ');
    while (parts.next()) |part| try w.print(" {c}{s}{c}", .{ quote, part, quote });
    try w.writeByte('\n');
}
