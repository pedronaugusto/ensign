//! Completion scripts, run in the real shells: subcommands at depth, aliases,
//! options with their values, negations, globals, clusters, `--` and
//! positionals by position.
const std = @import("std");
const ensign = @import("../ensign.zig");
const shells = @import("shells.zig");

const Shade = enum { light, dark };

const Add = struct {
    force: bool = false,
    shade: Shade = .light,
    url: []const u8,

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Add a remote",
        .options = .{
            .force = .{ .short = 'f', .help = "Replace one that exists" },
            .shade = .{ .help = "Its colour in listings" },
            .url = .{ .positional = true },
        },
    };
};

const Remove = struct {
    name: []const u8,
    pub const spec: ensign.Spec(@This()) = .{ .about = "Remove a remote", .options = .{ .name = .{ .positional = true } } };
};

const Remote = struct {
    command: union(enum) { add: Add, remove: Remove },
    pub const spec: ensign.Spec(@This()) = .{ .about = "Manage remotes", .commands = .{ .remove = .{ .aliases = &.{"rm"} } } };
};

const Build = struct {
    release: bool = true,
    out: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    secret: bool = false,
    tint: Shade = .light,
    key: Shade = .light,
    with: ?[]const u8 = null,
    level: Shade,
    files: []const []const u8 = &.{},

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Build it's parts",
        .options = .{
            .release = .{ .help = "Optimize" },
            .out = .{ .short = 'o', .hint = .file, .help = "Where to write" },
            .dir = .{ .short = 'C', .hint = .directory, .help = "Where to start" },
            .secret = .{ .hidden = true },
            .tint = .{ .aliases = &.{"hue"}, .help = "The colour of its output" },
            .key = .{ .hidden = true },
            .with = .{ .short = 'w', .hint = .command, .help = "A program to build with" },
            .level = .{ .positional = true },
            .files = .{ .positional = true, .hint = .file },
        },
    };
};

pub const Tool = struct {
    color: enum { auto, never } = .auto,
    quiet: bool = false,
    pager: bool = true,
    command: union(enum) { build: Build, remote: Remote },

    pub const spec: ensign.Spec(@This()) = .{
        .name = "tool",
        .options = .{
            .color = .{ .global = true, .help = "When to colour" },
            .quiet = .{ .short = 'q' },
            .pager = .{ .global = true, .help = "Page long output" },
        },
        .commands = .{ .build = .{ .aliases = &.{"b"} } },
    };
};

const cases = [_]shells.Case{
    .{ .line = "tool ", .want = "build remote" },
    .{ .line = "tool --c", .want = "--color" },
    .{ .line = "tool -", .want = "--color --help --no-pager --pager --quiet -h -q" },
    .{ .line = "tool bu", .want = "build" },
    .{ .line = "tool b --", .want = "--color --dir --help --no-pager --no-release --out --pager --release --tint --with" },
    .{ .line = "tool build --color=n", .want = "--color=never" },
    .{ .line = "tool build -o al", .want = "alpha.txt" },
    .{ .line = "tool build -o ./al", .want = "./alpha.txt" },
    .{ .line = "tool build -C s", .want = "sub", .fish = "sub/" },
    .{ .line = "tool build -C sub ", .want = "dark light" },
    .{ .line = "tool build -Csub ", .want = "dark light" },
    .{ .line = "tool build --out x light be", .want = "beta.zig" },
    .{ .line = "tool build dark alpha.txt be", .want = "beta.zig" },
    .{ .line = "tool build -- li", .want = "light" },
    .{ .line = "tool -q build --color never d", .want = "dark" },
    .{ .line = "tool remote ", .want = "add remove" },
    .{ .line = "tool remote add -", .want = "--color --force --help --no-pager --pager --shade -f -h" },
    .{ .line = "tool remote add --no-p", .want = "--no-pager" },
    .{ .line = "tool build --hue ", .want = "dark light" },
    .{ .line = "tool build --key ", .want = "dark light" },
    .{ .line = "tool build -o=x ", .want = "dark light" },
    .{ .line = "tool build --with ", .want = "<commands>", .only = .zsh },
    .{ .line = "tool remote add --shade ", .want = "dark light" },
    .{ .line = "tool remote add -f --shade=d", .want = "--shade=dark" },
    .{ .line = "tool remote rm --h", .want = "--help" },
};

fn run(shell: shells.Shell) !void {
    try shells.check(Tool, shell, "tool", &cases);
}

test "bash completes the tree, and values it split at '='" {
    // bash hands `--name=value` over as three words when `=` breaks words.
    const split = cases ++ [_]shells.Case{
        .{ .line = "tool build --color =", .want = "auto never" },
        .{ .line = "tool build --color = n", .want = "never" },
        .{ .line = "tool build --color = never li", .want = "light" },
        .{ .line = "tool build -o = x ", .want = "dark light" },
    };
    try shells.check(Tool, .bash, "tool", &split);
}

test "zsh completes the tree" {
    try run(.zsh);
}

test "fish completes the tree" {
    try run(.fish);
}

test "PowerShell completes the tree" {
    try run(.powershell);
}

fn script(shell: ensign.Shell) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer w.deinit();
    try ensign.writeCompletion(Tool, shell, &w.writer, "my-tool.v2");
    return w.toOwnedSlice();
}

test "scripts name the program and keep hidden options out of offers" {
    inline for (.{ .bash, .zsh, .fish, .powershell }) |shell| {
        const text = try script(shell);
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.find(u8, text, "my-tool.v2") != null);
        try std.testing.expect(std.mem.find(u8, text, "_my_tool_v2") != null or shell == .powershell);
        // The hidden flag is known, so a walk skips it, and never offered.
        try std.testing.expect(std.mem.find(u8, text, "--secret") != null);
        try std.testing.expect(std.mem.find(u8, text, "--secret --") == null);
    }
}

test "a program name a script cannot hold is refused" {
    var buffer: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.InvalidName, ensign.writeCompletion(Tool, .bash, &w, "my tool"));
    try std.testing.expectError(error.InvalidName, ensign.writeCompletion(Tool, .fish, &w, ""));
    try std.testing.expectError(error.InvalidName, ensign.writeCompletion(Tool, .zsh, &w, "a'b"));
}

/// No subcommands and no enum values: the lookups that would hold them are empty.
const Flat = struct {
    out: ?[]const u8 = null,
    verbose: bool = false,
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .out = .{ .short = 'o', .hint = .file } } };
};

const flat_cases = [_]shells.Case{
    .{ .line = "flat --o", .want = "--out" },
    .{ .line = "flat -o al", .want = "alpha.txt" },
    .{ .line = "flat -", .want = "--help --out --verbose -h -o" },
};

test "a flat command completes in every shell" {
    inline for (.{ .bash, .zsh, .fish, .powershell }) |shell| {
        shells.check(Flat, shell, "flat", &flat_cases) catch |err| switch (err) {
            error.SkipZigTest => {},
            else => return err,
        };
    }
}
