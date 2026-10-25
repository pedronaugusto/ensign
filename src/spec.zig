//! The declaration a program writes beside its arguments type: what each
//! field is called on the command line, its help, and the command's text.
const std = @import("std");
const text = @import("text.zig");

/// What a shell completes for an option's value or a positional.
pub const Hint = enum {
    /// Nothing beyond enum values: the value is free text.
    none,
    /// A path to a file.
    file,
    /// A path to a directory.
    directory,
    /// The name of a program on the search path.
    command,
};

/// One field's command-line spelling and help.
pub const Option = struct {
    /// One line or a paragraph; help wraps it to the terminal.
    help: []const u8 = "",
    /// `-x`: an ASCII letter or digit.
    short: ?u8 = null,
    /// The long name; the field name with `_` written `-` when null.
    long: ?[]const u8 = null,
    /// Further long names that set the same field. Help shows none of them.
    aliases: []const []const u8 = &.{},
    /// The value's name in help and errors; the long name in capitals when null.
    value_name: ?[]const u8 = null,
    /// A variable read when the command line does not give the option:
    /// the command line wins over it, and it wins over the default.
    env: ?[]const u8 = null,
    /// Taken by position instead of by name, in declaration order.
    positional: bool = false,
    /// An integer counting how often the option is given, as `-vvv`.
    count: bool = false,
    /// Also accepted after any subcommand below this command. Its value
    /// stays in this command's field.
    global: bool = false,
    /// Parsed, but absent from help and completions.
    hidden: bool = false,
    /// For a boolean: `--no-<long>` sets it false.
    negatable: bool = true,
    /// For a list: one argument can hold several values, split at this byte.
    delimiter: ?u8 = null,
    /// What a shell completes for the value.
    hint: Hint = .none,
    /// The heading this option is listed under in help; "Options" when null.
    section: ?[]const u8 = null,
    /// For the last positional, a list of text: from the first argument this
    /// command does not read as one of its options, every argument as it is,
    /// dashes and `--` included, as a program that wraps another passes them
    /// on (`bay build -Doptimize=ReleaseSafe`). A `--` before them is dropped.
    raw: bool = false,
};

/// A subcommand's spelling and its line in its parent's help.
pub const Command = struct {
    /// The line in the parent's command list; the subcommand's `about`
    /// when empty.
    help: []const u8 = "",
    /// The name; the tag with `_` written `-` when null.
    name: ?[]const u8 = null,
    /// Further names that select it.
    aliases: []const []const u8 = &.{},
    /// Selectable, but absent from help and completions.
    hidden: bool = false,
};

/// The payload of a subcommand that takes any name no other subcommand has,
/// with every argument after the name as it is: commands the program finds at
/// run time, as git's and cargo's external commands are. Its `Command.name`
/// is how help shows it, such as `<step>`. A command has at most one.
pub const External = struct {
    /// The name given.
    name: []const u8,
    /// Every argument after the name, as given.
    args: []const []const u8 = &.{},
};

/// A command line shown in help, with what it does.
pub const Example = struct {
    command: []const u8,
    help: []const u8 = "",
};

/// A titled block of text at the end of help.
pub const Section = struct {
    heading: []const u8,
    body: []const u8,
};

/// A flag the parser answers itself: `--help` or `--version`.
pub const Flag = struct {
    long: []const u8,
    short: ?u8 = null,
};

/// The declaration of a command whose arguments are `T`: a struct whose
/// fields are its options and positionals, and at most one tagged union (or
/// optional tagged union) whose variants are its subcommands. A type declares
/// it as `pub const spec: ensign.Spec(@This()) = .{ ... };`; a type without one
/// takes every default.
pub fn Spec(comptime T: type) type {
    return struct {
        /// The program's name at the root; ignored below it, where a
        /// command's name is its tag's.
        name: ?[]const u8 = null,
        /// Printed by `--version`; there is no `--version` without one.
        version: ?[]const u8 = null,
        /// One line: what the command does.
        about: []const u8 = "",
        /// Paragraphs below the usage line.
        description: []const u8 = "",
        /// Each field's spelling, keyed by field name.
        options: Options(T) = .{},
        /// Each subcommand's spelling, keyed by tag.
        commands: Commands(T) = .{},
        /// Groups of options of which the command line may give at most one.
        /// A value from the environment is dropped when the command line
        /// gives another option of its group.
        conflicts: []const []const Field(T) = &.{},
        /// Options that need others: when `option` is given, by the command
        /// line or the environment, each of `needs` must be given too.
        requires: []const Requires(T) = &.{},
        /// Groups of options of which the command line or the environment
        /// must give at least one. A group also in `conflicts` takes exactly one.
        required_groups: []const []const Field(T) = &.{},
        /// Values an option sets when it is given: each field of `sets` that
        /// is not null, unless the command line or the environment gives that
        /// field itself. The command line wins over the environment, the
        /// environment over an implied value, and that over the default.
        implies: []const Implies(T) = &.{},
        examples: []const Example = &.{},
        sections: []const Section = &.{},
        /// The help flag; null leaves `--help` to the program.
        help: ?Flag = .{ .long = "help", .short = 'h' },
        /// The version flag, when `version` is set; null leaves it to the program.
        version_flag: ?Flag = .{ .long = "version", .short = 'V' },
    };
}

/// The fields of `T` a spec may name.
pub fn Field(comptime T: type) type {
    return std.meta.FieldEnum(T);
}

/// An option of `T` that needs others.
pub fn Requires(comptime T: type) type {
    return struct {
        option: Field(T),
        /// Each must be given whenever `option` is.
        needs: []const Field(T),
    };
}

/// The values an option of `T` sets when it is given.
pub fn Implies(comptime T: type) type {
    return struct {
        option: Field(T),
        /// A value for any option; null leaves it alone.
        sets: Partial(T) = .{},
    };
}

/// A struct with an optional value for each field of `T` but its subcommand
/// field, each null by default.
pub fn Partial(comptime T: type) type {
    @setEvalBranchQuota(text.branch_quota);
    const fields = @typeInfo(T).@"struct";
    var names: [fields.field_names.len][:0]const u8 = undefined;
    var types: [fields.field_names.len]type = undefined;
    var attrs: [fields.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    var len: usize = 0;
    for (fields.field_names, fields.field_types) |name, F| {
        if (isCommands(F)) continue;
        const none: ?F = null;
        names[len] = name;
        types[len] = ?F;
        attrs[len] = .{ .default_value_ptr = &none };
        len += 1;
    }
    const final_names = names[0..len].*;
    const final_types = types[0..len].*;
    const final_attrs = attrs[0..len].*;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

/// A struct with an `Option` for each field of `T` but its subcommand field.
pub fn Options(comptime T: type) type {
    @setEvalBranchQuota(text.branch_quota);
    const fields = @typeInfo(T).@"struct";
    var names: [fields.field_names.len][:0]const u8 = undefined;
    var len: usize = 0;
    for (fields.field_names, fields.field_types) |name, F| {
        if (isCommands(F)) continue;
        names[len] = name;
        len += 1;
    }
    const default: Option = .{};
    const final = names[0..len].*;
    return @Struct(.auto, null, &final, &@splat(Option), &@splat(.{ .default_value_ptr = &default }));
}

/// A struct with a `Command` for each variant of `T`'s subcommand union.
pub fn Commands(comptime T: type) type {
    @setEvalBranchQuota(text.branch_quota);
    const fields = @typeInfo(T).@"struct";
    for (fields.field_types) |F| {
        if (!isCommands(F)) continue;
        const variants = @typeInfo(Unwrapped(F)).@"union";
        const default: Command = .{};
        return @Struct(.auto, null, variants.field_names, &@splat(Command), &@splat(.{ .default_value_ptr = &default }));
    }
    return struct {};
}

/// Whether a field of this type holds subcommands: a tagged union or an
/// optional one, unless the union reads itself as one value (it declares
/// `ensign_value`).
pub fn isCommands(comptime F: type) bool {
    return switch (@typeInfo(Unwrapped(F))) {
        .@"union" => |u| u.tag_type != null and !@hasDecl(Unwrapped(F), "ensign_value"),
        else => false,
    };
}

/// `F` without one level of optional.
pub fn Unwrapped(comptime F: type) type {
    return switch (@typeInfo(F)) {
        .optional => |o| o.child,
        else => F,
    };
}

test "a spec names fields and variants" {
    const Run = struct { fast: bool = false };
    const T = struct {
        level: u8 = 0,
        command: ?union(enum) { run: Run, stop },
    };
    const s: Spec(T) = .{ .options = .{ .level = .{ .short = 'l' } }, .commands = .{ .run = .{ .aliases = &.{"r"} } } };
    try std.testing.expectEqual(@as(?u8, 'l'), s.options.level.short);
    try std.testing.expectEqualStrings("r", s.commands.run.aliases[0]);
    try std.testing.expect(!@hasField(Options(T), "command"));
    try std.testing.expect(isCommands(@FieldType(T, "command")));
}
