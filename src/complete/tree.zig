//! The command tree as the completion scripts see it: for each command, every
//! spelling the line may hold there and what follows it.
const std = @import("std");
const model = @import("../model.zig");
const text = @import("../text.zig");
const value = @import("../value.zig");

/// What a spelling or a positional takes.
pub const Kind = enum {
    /// Nothing: a flag or a count.
    flag,
    /// Free text: nothing to offer.
    text,
    /// One of `values`.
    values,
    file,
    directory,
    command,
};

/// One option at one command, under every spelling.
pub const Entry = struct {
    /// Every spelling the parser accepts there: `--long`, aliases, `-s`.
    spellings: []const []const u8,
    /// The spellings offered when completing an option: `--long`, its
    /// negation when help shows it, and `-s`.
    offered: []const []const u8,
    kind: Kind,
    values: []const []const u8 = &.{},
    help: []const u8,
    hidden: bool,
};

pub const Sub = struct {
    name: []const u8,
    aliases: []const []const u8,
    help: []const u8,
    hidden: bool,
    /// The path of the command it selects.
    path: []const u8,
};

pub const Positional = struct {
    kind: Kind,
    values: []const []const u8 = &.{},
    /// It takes every argument from its position on.
    list: bool,
};

pub const Node = struct {
    /// The subcommand names below the program, space-separated; empty at the root.
    path: []const u8,
    entries: []const Entry,
    subs: []const Sub,
    positionals: []const Positional,
};

/// Every command of `T`'s tree, the root first.
pub fn nodes(comptime T: type) []const Node {
    @setEvalBranchQuota(text.branch_quota);
    return walk(T, "", &.{});
}

fn walk(comptime T: type, comptime path: []const u8, comptime inherited: []const Entry) []const Node {
    const i = model.info(T);
    var entries: []const Entry = &.{};
    var globals: []const Entry = inherited;
    for (i.options) |o| {
        const e = entry(o);
        entries = entries ++ .{e};
        if (o.meta.global) globals = globals ++ .{e};
        if (o.kind == .flag and o.meta.negatable) entries = entries ++ .{Entry{
            .spellings = &.{"--no-" ++ o.long},
            .offered = if (o.shows_negation and !o.meta.hidden) &.{"--no-" ++ o.long} else &.{},
            .kind = .flag,
            .help = firstLine(o.meta.help),
            .hidden = !o.shows_negation or o.meta.hidden,
        }};
    }
    for (model.builtins(i)) |f| {
        const spellings: []const []const u8 = &(.{"--" ++ f.long} ++ (if (f.short) |c| .{"-" ++ .{c}} else .{}));
        const is_help = if (i.specOf().help) |h| std.mem.eql(u8, h.long, f.long) else false;
        entries = entries ++ .{Entry{ .spellings = spellings, .offered = spellings, .kind = .flag, .help = if (is_help) "Print help" else "Print the version", .hidden = false }};
    }
    var subs: []const Sub = &.{};
    var below: []const Node = &.{};
    if (i.commands) |c| for (c.list) |sub| {
        const child = if (path.len == 0) sub.name else path ++ " " ++ sub.name;
        const help = if (sub.meta.help.len != 0) sub.meta.help else if (sub.Payload == void) "" else model.info(sub.Payload).specOf().about;
        subs = subs ++ .{Sub{ .name = sub.name, .aliases = sub.aliases, .help = firstLine(help), .hidden = sub.meta.hidden, .path = child }};
        below = below ++ if (sub.Payload == void)
            .{Node{ .path = child, .entries = globals ++ helpOnly(), .subs = &.{}, .positionals = &.{} }}
        else
            walk(sub.Payload, child, globals);
    };
    var positionals: []const Positional = &.{};
    for (i.positionals) |p| positionals = positionals ++ .{Positional{ .kind = kindOf(p), .values = valuesOf(p), .list = p.kind == .list }};
    return .{Node{ .path = path, .entries = entries ++ inherited, .subs = subs, .positionals = positionals }} ++ below;
}

fn helpOnly() []const Entry {
    return &.{Entry{ .spellings = &.{ "--help", "-h" }, .offered = &.{ "--help", "-h" }, .kind = .flag, .help = "Print help", .hidden = false }};
}

fn entry(comptime o: model.Opt) Entry {
    var spellings: []const []const u8 = &.{"--" ++ o.long};
    for (o.aliases) |alias| spellings = spellings ++ .{"--" ++ alias};
    var offered: []const []const u8 = &.{"--" ++ o.long};
    if (o.short) |c| {
        spellings = spellings ++ .{"-" ++ .{c}};
        offered = offered ++ .{"-" ++ .{c}};
    }
    return .{
        .spellings = spellings,
        .offered = if (o.meta.hidden) &.{} else offered,
        .kind = kindOf(o),
        .values = valuesOf(o),
        .help = firstLine(o.meta.help),
        .hidden = o.meta.hidden,
    };
}

fn kindOf(comptime o: model.Opt) Kind {
    if (!o.takesValue()) return .flag;
    if (@typeInfo(o.Value) == .@"enum") return .values;
    return switch (o.meta.hint) {
        .none => .text,
        .file => .file,
        .directory => .directory,
        .command => .command,
    };
}

fn valuesOf(comptime o: model.Opt) []const []const u8 {
    if (o.takesValue() and @typeInfo(o.Value) == .@"enum") return value.names(o.Value);
    return &.{};
}

/// The first line of a help text.
pub fn firstLine(comptime help: []const u8) []const u8 {
    return help[0 .. std.mem.findScalar(u8, help, '\n') orelse help.len];
}

/// Whether a program name can be written into every script as it is.
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "-_.+", c) == null) return false;
    }
    return true;
}

/// Writes `name` as a shell function name: letters, digits and `_`.
pub fn writeIdentifier(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    for (name) |c| try w.writeByte(if (std.ascii.isAlphanumeric(c)) c else '_');
}

/// The kinds as the scripts name them.
pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

test "nodes" {
    const Build = struct {
        release: bool = true,
        out: ?[]const u8 = null,
        pub const spec: @import("../spec.zig").Spec(@This()) = .{ .options = .{ .out = .{ .hint = .file, .short = 'o' } } };
    };
    const T = struct {
        color: enum { auto, never } = .auto,
        command: union(enum) { build: Build, stop },
        pub const spec: @import("../spec.zig").Spec(@This()) = .{ .options = .{ .color = .{ .global = true } } };
    };
    const all = comptime nodes(T);
    try std.testing.expectEqual(3, all.len);
    try std.testing.expectEqualStrings("build", all[1].path);
    try std.testing.expectEqual(Kind.values, all[0].entries[0].kind);
    try std.testing.expectEqualStrings("--no-release", all[1].entries[1].offered[0]);
    try std.testing.expectEqualStrings("--color", all[1].entries[all[1].entries.len - 1].spellings[0]);
    try std.testing.expectEqualStrings("stop", all[2].path);
}
