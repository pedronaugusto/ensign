//! A declaration read at compile time: each command's options, positionals
//! and subcommands, with every name the command line may use. A declaration
//! that cannot be parsed unambiguously is a compile error naming the field.
const std = @import("std");
const spec = @import("spec.zig");
const text = @import("text.zig");
const kinds = @import("kinds.zig");

/// How an option takes its value.
pub const Kind = enum {
    /// A boolean: given, or `--no-<long>`.
    flag,
    /// An integer that counts occurrences.
    count,
    /// One value; a later one replaces an earlier one.
    single,
    /// A slice: each occurrence adds values.
    list,
};

/// One field of a command, an option or a positional.
pub const Opt = struct {
    field: [:0]const u8,
    /// Its position among the command's options, or among its positionals.
    index: usize,
    /// The primary long name without dashes; empty for a positional.
    long: []const u8,
    aliases: []const []const u8,
    short: ?u8,
    kind: Kind,
    /// The field's type.
    Field: type,
    /// The type one value parses to: the element of a list, the child of an optional.
    Value: type,
    /// The field is optional (`?T`).
    optional: bool,
    /// No default and not optional: the command line or the environment must give it.
    required: bool,
    positional: bool,
    meta: spec.Option,
    value_name: []const u8,
    /// The field's default, read through `default`.
    attrs: std.lang.Type.Struct.FieldAttributes,
    /// Help shows `--[no-]name`: the flag is true by default or optional.
    shows_negation: bool,

    /// Whether the option reads a value after its name.
    pub fn takesValue(comptime o: Opt) bool {
        return o.kind == .single or o.kind == .list;
    }

    /// The field's default, when it has one.
    pub fn default(comptime o: Opt) ?o.Field {
        return o.attrs.defaultValue(o.Field);
    }
};

/// One variant of a command's subcommand union.
pub const Sub = struct {
    tag: [:0]const u8,
    name: []const u8,
    aliases: []const []const u8,
    meta: spec.Command,
    /// The variant's payload: a struct, or void for a command with no arguments.
    Payload: type,
    /// Its payload is `spec.External`: it takes any name no other variant has.
    external: bool,
};

/// A command's subcommands: the field holding them and its variants.
pub const Subs = struct {
    field: [:0]const u8,
    Union: type,
    /// The field is `?Union`: no subcommand is allowed.
    optional: bool,
    list: []const Sub,

    /// The variant that takes names no other has, if one does.
    pub fn external(comptime c: Subs) ?Sub {
        for (c.list) |sub| if (sub.external) return sub;
        return null;
    }
};

/// Everything the parser, help and completions read about a command.
pub const Info = struct {
    T: type,
    options: []const Opt,
    positionals: []const Opt,
    commands: ?Subs,

    pub fn specOf(comptime i: Info) spec.Spec(i.T) {
        return declared(i.T).*;
    }

    /// Whether the command answers `--version`.
    pub fn version(comptime i: Info) ?spec.Flag {
        const s = i.specOf();
        return if (s.version != null) s.version_flag else null;
    }

    /// The options other commands below this one also accept.
    pub fn globals(comptime i: Info) []const Opt {
        return comptime blk: {
            @setEvalBranchQuota(text.branch_quota);
            var out: []const Opt = &.{};
            for (i.options) |o| {
                if (o.meta.global) out = out ++ .{o};
            }
            break :blk out;
        };
    }
};

/// The declaration of `T`, from its `spec` or every default.
pub fn declared(comptime T: type) *const spec.Spec(T) {
    return comptime blk: {
        @setEvalBranchQuota(text.branch_quota);
        if (!@hasDecl(T, "spec")) {
            const empty: spec.Spec(T) = .{};
            break :blk &empty;
        }
        if (@TypeOf(T.spec) != spec.Spec(T)) @compileError("ensign: " ++ @typeName(T) ++ ".spec must be declared `pub const spec: ensign.Spec(@This())`");
        break :blk &T.spec;
    };
}

/// Reads `T`, a command's arguments type.
pub fn info(comptime T: type) Info {
    return comptime blk: {
        @setEvalBranchQuota(text.branch_quota);
        if (@typeInfo(T) != .@"struct") @compileError("ensign: a command's arguments are a struct, not " ++ @typeName(T));
        const s = declared(T);
        const fields = @typeInfo(T).@"struct";
        var options: []const Opt = &.{};
        var positionals: []const Opt = &.{};
        var commands: ?Subs = null;
        for (fields.field_names, fields.field_types, fields.field_attrs) |name, F, attrs| {
            if (spec.isCommands(F)) {
                if (commands != null) @compileError("ensign: " ++ @typeName(T) ++ " has two subcommand fields; a command has at most one");
                commands = subsOf(T, name, F, attrs, s);
                continue;
            }
            const meta = @field(s.options, name);
            const o = option(T, name, F, attrs, meta, if (meta.positional) positionals.len else options.len);
            if (meta.positional) positionals = positionals ++ .{o} else options = options ++ .{o};
        }
        const result: Info = .{ .T = T, .options = options, .positionals = positionals, .commands = commands };
        validate(result);
        break :blk result;
    };
}

fn subsOf(comptime T: type, comptime field: [:0]const u8, comptime F: type, comptime attrs: anytype, comptime s: anytype) Subs {
    const U = spec.Unwrapped(F);
    const optional = F != U;
    if (!optional and attrs.default_value_ptr != null) @compileError("ensign: " ++ @typeName(T) ++ "." ++ field ++ ": a required subcommand has no default; make the field optional");
    const u = @typeInfo(U).@"union";
    var list: []const Sub = &.{};
    var externals = 0;
    for (u.field_names, u.field_types) |tag, P| {
        if (P != void and @typeInfo(P) != .@"struct") @compileError("ensign: subcommand " ++ tag ++ " of " ++ @typeName(T) ++ " holds a " ++ @typeName(P) ++ "; a subcommand holds a struct or nothing");
        const meta = @field(s.commands, tag);
        const external = P == spec.External;
        if (external) {
            externals += 1;
            if (externals > 1) @compileError("ensign: " ++ @typeName(T) ++ "." ++ field ++ " has two external subcommands; a command has at most one");
            if (meta.aliases.len != 0) @compileError("ensign: " ++ @typeName(T) ++ "." ++ tag ++ ": an external subcommand takes any name, so it has no aliases");
        }
        // An external subcommand's name is how help shows it, such as `<step>`.
        const name = meta.name orelse if (external) "<" ++ text.dashed(tag) ++ ">" else text.dashed(tag);
        if (!external) checkName(T, name, "subcommand");
        for (meta.aliases) |alias| checkName(T, alias, "subcommand alias");
        list = list ++ .{Sub{ .tag = tag, .name = name, .aliases = meta.aliases, .meta = meta, .Payload = P, .external = external }};
    }
    if (list.len == 0) @compileError("ensign: " ++ @typeName(T) ++ "." ++ field ++ " has no subcommands");
    return .{ .field = field, .Union = U, .optional = optional, .list = list };
}

fn option(comptime T: type, comptime name: [:0]const u8, comptime F: type, comptime attrs: anytype, comptime meta: spec.Option, comptime index: usize) Opt {
    const where = @typeName(T) ++ "." ++ name;
    const has_default = attrs.default_value_ptr != null;
    const Child = spec.Unwrapped(F);
    const optional = Child != F;
    if (optional and @typeInfo(Child) == .optional) @compileError("ensign: " ++ where ++ ": nested optionals mean nothing on a command line");
    var kind: Kind = .single;
    var Value = Child;
    if (Child == bool) {
        kind = .flag;
        if (!has_default and !optional) @compileError("ensign: " ++ where ++ ": a boolean needs a default, or `?bool` to tell absent from false");
    } else if (isList(Child)) {
        if (optional) @compileError("ensign: " ++ where ++ ": a list is already empty when absent; drop the optional");
        kind = .list;
        Value = @typeInfo(Child).pointer.child;
    }
    if (meta.count) {
        if (@typeInfo(F) != .int) @compileError("ensign: " ++ where ++ ": a count is an integer, not " ++ @typeName(F));
        if (!has_default) @compileError("ensign: " ++ where ++ ": a count needs a default");
        kind = .count;
    }
    if (kind != .flag and kind != .count) checkValue(where, Value);
    if (meta.delimiter != null and kind != .list) @compileError("ensign: " ++ where ++ ": a delimiter splits list values; the field is no list");
    if (meta.raw) {
        if (!meta.positional or kind != .list or kinds.of(Value) != .text) @compileError("ensign: " ++ where ++ ": raw arguments are a positional list of text, []const []const u8");
        if (meta.delimiter != null) @compileError("ensign: " ++ where ++ ": raw arguments are taken as given; a delimiter would split them");
    }
    if (meta.positional) {
        if (kind == .flag or kind == .count) @compileError("ensign: " ++ where ++ ": a positional takes a value; a flag or count cannot be one");
        if (meta.short != null or meta.long != null or meta.aliases.len != 0) @compileError("ensign: " ++ where ++ ": a positional has no option names");
        if (meta.global or meta.env != null) @compileError("ensign: " ++ where ++ ": a positional cannot be global or read the environment");
    }
    const long = if (meta.positional) "" else meta.long orelse text.dashed(name);
    if (!meta.positional) {
        checkName(T, long, "option");
        for (meta.aliases) |alias| checkName(T, alias, "option alias");
        if (meta.short) |c| {
            if (!std.ascii.isAlphanumeric(c)) @compileError("ensign: " ++ where ++ ": a short option is an ASCII letter or digit");
        }
    }
    return .{
        .field = name,
        .index = index,
        .long = long,
        .aliases = meta.aliases,
        .short = meta.short,
        .kind = kind,
        .Field = F,
        .Value = Value,
        .optional = optional,
        .required = !has_default and !optional,
        .positional = meta.positional,
        .meta = meta,
        .attrs = attrs,
        .value_name = meta.value_name orelse text.upper(if (meta.positional) name else long),
        .shows_negation = kind == .flag and meta.negatable and (optional or (has_default and attrs.defaultValue(F).? == true)),
    };
}

fn isList(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .pointer => |p| p.size == .slice and p.attrs.@"const" and p.child != u8,
        else => false,
    };
}

fn checkValue(comptime where: []const u8, comptime V: type) void {
    switch (kinds.of(V)) {
        .integer, .float, .checked, .duration, .size, .custom => {},
        .enumeration => for (@typeInfo(V).@"enum".field_names) |tag| checkName(V, text.dashed(tag), "enum value"),
        .text => {
            const p = @typeInfo(V).pointer;
            if (p.size != .slice or p.child != u8 or !p.attrs.@"const" or p.sentinel_ptr != null)
                @compileError("ensign: " ++ where ++ ": text is []const u8, not " ++ @typeName(V));
        },
        .boolean, .none => if (@typeInfo(V) == .@"enum")
            @compileError("ensign: " ++ where ++ ": " ++ @typeName(V) ++ " is a non-exhaustive enum, whose values have no names to read; make it exhaustive, or use an aegis integer, Duration or Bytes")
        else
            @compileError("ensign: " ++ where ++ ": " ++ @typeName(V) ++ " is no command-line value; use an integer, float, enum, bool, []const u8, an aegis integer, Duration or Bytes, a type declaring ensign_value, or a slice of one"),
    }
}

/// A name the command line spells: a letter or digit, then letters, digits,
/// `-`, `_`, `.` or `+`, so that every shell's completion can hold it.
fn checkName(comptime T: type, comptime name: []const u8, comptime what: []const u8) void {
    const bad = name.len == 0 or !std.ascii.isAlphanumeric(name[0]) or for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "-_.+", c) == null) break true;
    } else false;
    if (bad) @compileError("ensign: " ++ @typeName(T) ++ ": " ++ what ++ " '" ++ name ++ "' must start with a letter or digit and hold only letters, digits, '-', '_', '.' or '+'");
}

fn validate(comptime i: Info) void {
    const s = i.specOf();
    const where = @typeName(i.T);
    // Every long name and short once, the built-in flags included.
    var longs: []const []const u8 = &.{};
    var shorts: []const u8 = &.{};
    for (builtins(i)) |f| {
        longs = longs ++ .{f.long};
        if (f.short) |c| shorts = shorts ++ .{c};
    }
    for (i.options) |o| {
        for (.{o.long} ++ o.aliases) |name| {
            for (longs) |seen| if (std.mem.eql(u8, seen, name)) @compileError("ensign: " ++ where ++ ": --" ++ name ++ " names two options");
            longs = longs ++ .{name};
        }
        if (o.short) |c| {
            if (std.mem.findScalar(u8, shorts, c) != null) @compileError("ensign: " ++ where ++ ": -" ++ .{c} ++ " names two options");
            shorts = shorts ++ .{c};
        }
    }
    for (i.options) |o| {
        if (o.kind != .flag or !o.meta.negatable) continue;
        for (longs) |seen| if (std.mem.eql(u8, seen, "no-" ++ o.long)) @compileError("ensign: " ++ where ++ ": --no-" ++ o.long ++ " is both an option and the negation of --" ++ o.long);
    }
    var optional_seen = false;
    for (i.positionals, 0..) |p, n| {
        if (p.kind == .list and n + 1 != i.positionals.len) @compileError("ensign: " ++ where ++ "." ++ p.field ++ ": a list positional takes the rest, so it comes last");
        if (p.required and optional_seen) @compileError("ensign: " ++ where ++ "." ++ p.field ++ ": a required positional cannot follow an optional one");
        if (!p.required) optional_seen = true;
    }
    if (i.commands != null and i.positionals.len != 0) @compileError("ensign: " ++ where ++ ": a command with subcommands takes no positionals");
    for (s.conflicts) |group| {
        if (group.len < 2) @compileError("ensign: " ++ where ++ ": a conflict names at least two options");
        for (group) |f| {
            const name = @tagName(f);
            const ok = for (i.options) |o| {
                if (std.mem.eql(u8, o.field, name)) break true;
            } else false;
            if (!ok) @compileError("ensign: " ++ where ++ ": conflicts name options, and " ++ name ++ " is none");
        }
    }
    if (i.commands) |c| {
        var names: []const []const u8 = &.{};
        for (c.list) |sub| if (!sub.external) for (.{sub.name} ++ sub.aliases) |name| {
            for (names) |seen| if (std.mem.eql(u8, seen, name)) @compileError("ensign: " ++ where ++ ": subcommand " ++ name ++ " is named twice");
            names = names ++ .{name};
        };
    }
}

/// The flags the parser answers for this command.
pub fn builtins(comptime i: Info) []const spec.Flag {
    return comptime blk: {
        @setEvalBranchQuota(text.branch_quota);
        const s = i.specOf();
        var out: []const spec.Flag = &.{};
        if (s.help) |f| out = out ++ .{f};
        if (i.version()) |f| out = out ++ .{f};
        break :blk out;
    };
}

/// Whether an option of a command below clashes with a global one above.
pub fn checkBelow(comptime above: Info, comptime below: Info) void {
    comptime {
        @setEvalBranchQuota(text.branch_quota);
        for (above.globals()) |g| for (below.options) |o| {
            for (.{g.long} ++ g.aliases) |a| for (.{o.long} ++ o.aliases) |b| {
                if (std.mem.eql(u8, a, b)) @compileError("ensign: " ++ @typeName(below.T) ++ ": --" ++ b ++ " hides the global option of " ++ @typeName(above.T));
            };
            if (g.short != null and g.short == o.short) @compileError("ensign: " ++ @typeName(below.T) ++ ": -" ++ .{g.short.?} ++ " hides the global option of " ++ @typeName(above.T));
        };
        // The flags the command below answers itself are its names too.
        for (above.globals()) |g| for (builtins(below)) |f| {
            for (.{g.long} ++ g.aliases) |a| {
                if (std.mem.eql(u8, a, f.long)) @compileError("ensign: " ++ @typeName(below.T) ++ ": its --" ++ f.long ++ " flag hides the global option of " ++ @typeName(above.T));
            }
            if (g.short != null and g.short == f.short) @compileError("ensign: " ++ @typeName(below.T) ++ ": its -" ++ .{g.short.?} ++ " flag hides the global option of " ++ @typeName(above.T));
        };
    }
}

test "info reads options, positionals and subcommands" {
    const Build = struct {
        release: bool = false,
        files: []const []const u8 = &.{},
        pub const spec: @import("spec.zig").Spec(@This()) = .{ .options = .{ .files = .{ .positional = true } } };
    };
    const T = struct {
        verbose: u8 = 0,
        dry_run: bool = true,
        name: []const u8,
        command: union(enum) { build: Build, stop },
        pub const spec: @import("spec.zig").Spec(@This()) = .{ .options = .{ .verbose = .{ .count = true, .short = 'v' } } };
    };
    const i = comptime info(T);
    try std.testing.expectEqual(3, i.options.len);
    try std.testing.expectEqual(Kind.count, i.options[0].kind);
    try std.testing.expectEqualStrings("dry-run", i.options[1].long);
    try std.testing.expect(i.options[1].shows_negation);
    try std.testing.expect(i.options[2].required);
    try std.testing.expectEqualStrings("NAME", i.options[2].value_name);
    try std.testing.expectEqual(2, i.commands.?.list.len);
    const b = comptime info(Build);
    try std.testing.expectEqual(Kind.list, b.positionals[0].kind);
    try std.testing.expectEqualStrings("FILES", b.positionals[0].value_name);
}
