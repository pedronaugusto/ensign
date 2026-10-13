//! The command line read against a declaration, one argument at a time.
//! Every command of the declaration is a `Frame` type the compiler builds:
//! its names are tables known at compile time, and each option's code is
//! its own branch.
const std = @import("std");
const model = @import("model.zig");
const text = @import("text.zig");
const value = @import("value.zig");
const help = @import("help.zig");
const lookup = @import("lookup.zig");
const diagnostic = @import("diagnostic.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Diagnostic = diagnostic.Diagnostic;
const Page = diagnostic.Page;
const Problem = diagnostic.Problem;

/// What parsing can fail with. Each error but `OutOfMemory` fills the
/// `Diagnostic` when one is given.
pub const Error = error{
    /// An option no command in reach declares.
    UnknownOption,
    /// A subcommand name the command does not have.
    UnknownCommand,
    /// An argument past the last positional.
    UnexpectedArgument,
    /// An option that takes a value came last.
    MissingValue,
    /// A flag or count was written `--name=value`.
    UnexpectedValue,
    /// A value that does not parse as the option's type.
    InvalidValue,
    /// A required option neither the command line nor the environment gave.
    MissingOption,
    /// A required positional is missing.
    MissingArgument,
    /// A required subcommand is missing.
    MissingCommand,
    /// Two options of one conflict group were given.
    Conflict,
    OutOfMemory,
};

/// What the parser answers itself, besides errors.
const Request = error{ HelpRequested, VersionRequested };

pub const Options = struct {
    /// The program's name in help and messages; the declaration's `name`
    /// when null, and then "program".
    name: ?[]const u8 = null,
    /// Where options with `env` look when the command line does not give them.
    environ: ?*const std.process.Environ.Map = null,
    /// Filled when parsing fails.
    diagnostic: ?*Diagnostic = null,
};

/// `--help` was given: the program shows this page and exits successfully.
pub const Help = struct {
    page: *const Page,
    program: []const u8,

    pub fn write(h: Help, w: *Writer, width: usize) Writer.Error!void {
        return h.page.writeHelp(w, h.program, width);
    }
};

/// `--version` was given: the program shows this and exits successfully.
pub const Version = struct {
    program: []const u8,
    version: []const u8,

    pub fn write(v: Version, w: *Writer) Writer.Error!void {
        try text.writeEscaped(w, v.program);
        try w.print(" {s}\n", .{v.version});
    }
};

/// The arguments, or a request the parser answered.
pub fn Outcome(comptime T: type) type {
    return union(enum) {
        parsed: T,
        help: Help,
        version: Version,
    };
}

/// A slice of arguments, without the program's name.
pub const Slice = struct {
    args: []const []const u8,
    index: usize = 0,

    pub fn next(s: *Slice) ?[]const u8 {
        if (s.index == s.args.len) return null;
        defer s.index += 1;
        return s.args[s.index];
    }
};

/// Parses the arguments `cursor.next()` gives into a `T`. Text values
/// borrow from the arguments and from the environment; lists are allocated
/// with `gpa` and released with `free`.
pub fn parseFrom(comptime T: type, gpa: Allocator, cursor: anytype, options: Options) Error!Outcome(T) {
    const s = model.declared(T);
    var st: State = .{
        .gpa = gpa,
        .environ = options.environ,
        .diagnostic = options.diagnostic,
        .program = options.name orelse s.name orelse "program",
    };
    var out: T = defaults(T);
    var root: Frame(&.{T}, &.{}, void) = .{ .out = &out, .parent = {} };
    root.run(&st, cursor) catch |err| switch (err) {
        error.HelpRequested => return .{ .help = .{ .page = st.page.?, .program = st.program } },
        error.VersionRequested => return .{ .version = .{ .program = st.program, .version = st.version } },
        else => |e| return e,
    };
    return .{ .parsed = out };
}

const State = struct {
    gpa: Allocator,
    environ: ?*const std.process.Environ.Map,
    diagnostic: ?*Diagnostic,
    program: []const u8,
    page: ?*const Page = null,
    version: []const u8 = "",

    fn fail(st: *State, err: Error, d: Diagnostic) Error {
        if (st.diagnostic) |out| {
            out.* = d;
            out.page = st.page;
            out.program = st.program;
        }
        return err;
    }
};

/// The two-byte spelling of each short option, for messages.
const dashes: [256][2]u8 = blk: {
    var out: [256][2]u8 = undefined;
    for (&out, 0..) |*d, c| d.* = .{ '-', c };
    break :blk out;
};

/// A value of `T` holding every default; a field without one is set later
/// or the parse fails.
fn defaults(comptime T: type) T {
    var out: T = undefined;
    const fields = @typeInfo(T).@"struct";
    inline for (fields.field_names, fields.field_types, fields.field_attrs) |name, F, attrs| {
        if (attrs.defaultValue(F)) |d| {
            @field(out, name) = d;
        } else if (@typeInfo(F) == .optional) {
            @field(out, name) = null;
        }
    }
    return out;
}

/// Releases the lists the parser allocated in `v`, and in its subcommand's.
pub fn free(comptime T: type, gpa: Allocator, v: *const T) void {
    const i = comptime model.info(T);
    inline for (i.options ++ i.positionals) |o| {
        if (o.kind == .list) freeList(o, gpa, @field(v, o.field));
    }
    freeCommand(T, gpa, v);
}

/// Releases the lists of `v`'s subcommand, if it has one.
fn freeCommand(comptime T: type, gpa: Allocator, v: *const T) void {
    const commands = comptime model.info(T).commands;
    if (commands) |c| {
        const u = if (c.optional) (@field(v, c.field) orelse return) else @field(v, c.field);
        switch (u) {
            inline else => |*payload| if (@TypeOf(payload.*) != void) free(@TypeOf(payload.*), gpa, payload),
        }
    }
}

fn freeList(comptime o: model.Opt, gpa: Allocator, list: o.Field) void {
    if (list.len == 0) return;
    if (o.default()) |d| if (d.ptr == list.ptr) return;
    gpa.free(list);
}

/// A command with its arguments struct `C`, the last of `chain`, below the
/// frames of `Parent`.
fn Frame(comptime chain: []const type, comptime names: []const []const u8, comptime Parent: type) type {
    return struct {
        const Self = @This();
        const C = chain[chain.len - 1];
        const info = model.info(C);
        const s = info.specOf();
        const Pg = help.Pages(chain, names);
        const n_options = info.options.len;

        out: *C,
        parent: if (Parent == void) void else *Parent,
        /// Options the command line gave.
        seen: std.bit_set.Static(n_options) = .empty,
        /// Options the command line or the environment gave.
        given: std.bit_set.Static(n_options) = .empty,
        /// List fields of `out` this frame allocated.
        owned: std.bit_set.Static(info.options.len + info.positionals.len) = .empty,
        lists: Lists = .{},
        positional: usize = 0,
        chose: bool = false,

        comptime {
            for (chain[0 .. chain.len - 1]) |Above| model.checkBelow(model.info(Above), info);
        }

        const Lists = blk: {
            @setEvalBranchQuota(text.branch_quota);
            var field_names: []const [:0]const u8 = &.{};
            var types: []const type = &.{};
            var attrs: []const std.lang.Type.Struct.FieldAttributes = &.{};
            for (info.options ++ info.positionals) |o| {
                if (o.kind != .list) continue;
                const L = std.ArrayList(o.Value);
                const empty: L = .empty;
                field_names = field_names ++ .{o.field};
                types = types ++ .{L};
                attrs = attrs ++ .{std.lang.Type.Struct.FieldAttributes{ .default_value_ptr = &empty }};
            }
            break :blk @Struct(.auto, null, field_names, types[0..types.len], attrs[0..attrs.len]);
        };

        /// Long names and aliases, each to its option's index.
        const longs = blk: {
            @setEvalBranchQuota(text.branch_quota);
            var kvs: []const lookup.Entry = &.{};
            for (info.options) |o| for (.{o.long} ++ o.aliases) |name| {
                kvs = kvs ++ .{.{ name, o.index }};
            };
            break :blk lookup.Table(kvs);
        };

        /// The same, for the options commands below may use.
        const global_longs = blk: {
            @setEvalBranchQuota(text.branch_quota);
            var kvs: []const lookup.Entry = &.{};
            for (info.globals()) |o| for (.{o.long} ++ o.aliases) |name| {
                kvs = kvs ++ .{.{ name, o.index }};
            };
            break :blk lookup.Table(kvs);
        };

        const shorts = table(false);
        const global_shorts = table(true);

        fn table(comptime only_global: bool) [256]?u16 {
            @setEvalBranchQuota(text.branch_quota);
            var out: [256]?u16 = @splat(null);
            for (info.options) |o| {
                if (only_global and !o.meta.global) continue;
                if (o.short) |c| out[c] = o.index;
            }
            return out;
        }

        /// Subcommand names and aliases, each to its variant's position.
        const subs = blk: {
            @setEvalBranchQuota(text.branch_quota);
            var kvs: []const lookup.Entry = &.{};
            if (info.commands) |c| for (c.list, 0..) |sub, n| for (.{sub.name} ++ sub.aliases) |name| {
                kvs = kvs ++ .{.{ name, n }};
            };
            break :blk lookup.Table(kvs);
        };

        /// Whether a short option is a digit here or above, so that `-5`
        /// cannot be read as a negative number.
        const digit_shorts = blk: {
            @setEvalBranchQuota(text.branch_quota);
            var any = false;
            for (info.options) |o| if (o.short) |c| {
                any = any or std.ascii.isDigit(c);
            };
            if (Parent != void) any = any or Parent.digit_shorts_below;
            break :blk any;
        };
        const digit_shorts_below = blk: {
            @setEvalBranchQuota(text.branch_quota);
            var any = false;
            for (info.globals()) |o| if (o.short) |c| {
                any = any or std.ascii.isDigit(c);
            };
            if (Parent != void) any = any or Parent.digit_shorts_below;
            break :blk any;
        };

        fn run(self: *Self, st: *State, cursor: anytype) (Error || Request)!void {
            st.page = &Pg.page;
            defer inline for (@typeInfo(Lists).@"struct".field_names) |name| @field(self.lists, name).deinit(st.gpa);
            var only_positionals = false;
            while (cursor.next()) |arg| {
                if (only_positionals) {
                    try self.positionalArg(st, arg);
                } else if (std.mem.eql(u8, arg, "--")) {
                    only_positionals = true;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    try self.long(st, cursor, arg);
                } else if (arg.len > 1 and arg[0] == '-' and !negativeNumber(arg)) {
                    try self.shortCluster(st, cursor, arg);
                } else if (info.commands != null) {
                    try self.command(st, cursor, arg);
                    errdefer self.releaseCommand(st);
                    return self.finish(st);
                } else {
                    try self.positionalArg(st, arg);
                }
            }
            return self.finish(st);
        }

        fn negativeNumber(arg: []const u8) bool {
            if (info.positionals.len == 0 or digit_shorts) return false;
            return std.ascii.isDigit(arg[1]) or (arg[1] == '.' and arg.len > 2 and std.ascii.isDigit(arg[2]));
        }

        fn long(self: *Self, st: *State, cursor: anytype, arg: []const u8) (Error || Request)!void {
            const eq = std.mem.findScalar(u8, arg, '=');
            const spelled = arg[0 .. eq orelse arg.len];
            const name = spelled[2..];
            const attached: ?[]const u8 = if (eq) |e| arg[e + 1 ..] else null;
            if (try self.applyLong(st, cursor, spelled, name, attached, false)) return;
            if (Parent != void) {
                if (try self.parent.applyLong(st, cursor, spelled, name, attached, true)) return;
            }
            if (s.help) |f| if (std.mem.eql(u8, name, f.long)) return self.request(st, attached, spelled, error.HelpRequested);
            if (info.version()) |f| if (std.mem.eql(u8, name, f.long)) return self.request(st, attached, spelled, error.VersionRequested);
            var nearest: text.Nearest = .{ .typed = spelled };
            self.considerLongs(&nearest, false);
            return st.fail(error.UnknownOption, .{ .problem = .unknown_option, .argument = spelled, .suggestion = nearest.best });
        }

        fn request(self: *Self, st: *State, attached: ?[]const u8, spelled: []const u8, comptime which: Request) (Error || Request)!void {
            _ = self;
            if (attached) |a| return st.fail(error.UnexpectedValue, .{ .problem = .unexpected_value, .option = spelled, .value = a });
            st.page = &Pg.page;
            if (which == error.VersionRequested) st.version = s.version.?;
            return which;
        }

        /// Every name a reader of this command could have meant, for a suggestion.
        fn considerLongs(self: *Self, nearest: *text.Nearest, only_global: bool) void {
            inline for (info.options) |o| {
                if (!o.meta.hidden and (!only_global or o.meta.global)) {
                    nearest.consider("--" ++ o.long);
                    if (o.shows_negation) nearest.consider("--no-" ++ o.long);
                }
            }
            if (!only_global) inline for (comptime model.builtins(info)) |f| nearest.consider("--" ++ f.long);
            if (Parent != void) self.parent.considerLongs(nearest, true);
        }

        /// Applies `--name` when this command declares it; with `only_global`,
        /// only an option commands below may use. Asks the commands above
        /// when `only_global` and this one has none.
        fn applyLong(self: *Self, st: *State, cursor: anytype, spelled: []const u8, name: []const u8, attached: ?[]const u8, only_global: bool) Error!bool {
            const found = if (only_global) global_longs.get(name) else longs.get(name);
            if (found) |index| {
                try self.apply(st, cursor, index, spelled, attached, false);
                return true;
            }
            if (std.mem.startsWith(u8, name, "no-")) if (if (only_global) global_longs.get(name[3..]) else longs.get(name[3..])) |index| {
                if (isNegatable(index)) {
                    try self.apply(st, cursor, index, spelled, attached, true);
                    return true;
                }
            };
            if (only_global and Parent != void) return self.parent.applyLong(st, cursor, spelled, name, attached, true);
            return false;
        }

        fn isNegatable(index: u16) bool {
            inline for (info.options) |o| {
                if (o.index == index) return o.kind == .flag and o.meta.negatable;
            }
            return false;
        }

        fn shortCluster(self: *Self, st: *State, cursor: anytype, arg: []const u8) (Error || Request)!void {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) {
                const c = arg[k];
                const rest = arg[k + 1 ..];
                const index = shorts[c] orelse {
                    if (Parent != void) {
                        if (try self.parent.applyShort(st, cursor, c, rest)) |took_rest| {
                            if (took_rest) return;
                            continue;
                        }
                    }
                    if (s.help) |f| if (f.short == c) return self.request(st, null, "", error.HelpRequested);
                    if (info.version()) |f| if (f.short == c) return self.request(st, null, "", error.VersionRequested);
                    return st.fail(error.UnknownOption, .{ .problem = .unknown_option, .argument = &dashes[c] });
                };
                if (try self.applyShortIndex(st, cursor, index, c, rest)) return;
            }
        }

        /// Applies the global short option `c` of this command or one above;
        /// null when none has it, else whether it took the rest of the cluster.
        fn applyShort(self: *Self, st: *State, cursor: anytype, c: u8, rest: []const u8) Error!?bool {
            if (global_shorts[c]) |index| return try self.applyShortIndex(st, cursor, index, c, rest);
            if (Parent != void) return self.parent.applyShort(st, cursor, c, rest);
            return null;
        }

        /// Applies short option `c`; returns whether it took the rest of the cluster.
        fn applyShortIndex(self: *Self, st: *State, cursor: anytype, index: u16, c: u8, rest: []const u8) Error!bool {
            if (!takesValue(index)) {
                try self.apply(st, cursor, index, &dashes[c], null, false);
                return false;
            }
            const attached: ?[]const u8 = if (rest.len == 0) null else if (rest[0] == '=') rest[1..] else rest;
            try self.apply(st, cursor, index, &dashes[c], attached, false);
            return true;
        }

        fn takesValue(index: u16) bool {
            inline for (info.options) |o| {
                if (o.index == index) return o.takesValue();
            }
            return false;
        }

        fn apply(self: *Self, st: *State, cursor: anytype, index: u16, spelled: []const u8, attached: ?[]const u8, negated: bool) Error!void {
            if (n_options == 0) unreachable else switch (index) { // unreachable: an index comes from this command's tables, which are empty without options
                inline 0...n_options - 1 => |i| try self.applyOption(st, cursor, info.options[i], spelled, attached, negated),
                else => unreachable, // unreachable: the tables hold only this command's option indices
            }
        }

        fn applyOption(self: *Self, st: *State, cursor: anytype, comptime o: model.Opt, spelled: []const u8, attached: ?[]const u8, negated: bool) Error!void {
            self.seen.set(o.index);
            self.given.set(o.index);
            switch (o.kind) {
                .flag => {
                    if (negated) {
                        if (attached) |a| return st.fail(error.UnexpectedValue, .{ .problem = .unexpected_value, .option = spelled, .value = a });
                        @field(self.out, o.field) = false;
                    } else if (attached) |a| {
                        @field(self.out, o.field) = value.boolean(a) orelse return invalid(st, o, a, null);
                    } else @field(self.out, o.field) = true;
                },
                .count => {
                    if (attached) |a| return st.fail(error.UnexpectedValue, .{ .problem = .unexpected_value, .option = spelled, .value = a });
                    @field(self.out, o.field) +|= 1;
                },
                .single, .list => {
                    const bytes = attached orelse cursor.next() orelse
                        return st.fail(error.MissingValue, .{ .problem = .missing_value, .option = display(o), .expected = value.expected(o.Value) });
                    if (o.kind == .single) {
                        @field(self.out, o.field) = try one(st, o, bytes, null);
                    } else try self.append(st, o, bytes, null);
                },
            }
        }

        fn one(st: *State, comptime o: model.Opt, bytes: []const u8, env: ?[]const u8) Error!o.Value {
            return value.parse(o.Value, bytes) orelse invalid(st, o, bytes, env);
        }

        fn invalid(st: *State, comptime o: model.Opt, bytes: []const u8, env: ?[]const u8) Error {
            const suggestion = if (@typeInfo(o.Value) == .@"enum") value.suggest(o.Value, bytes) else null;
            const expected = if (o.kind == .flag) value.expected(bool) else value.expected(o.Value);
            return st.fail(error.InvalidValue, .{ .problem = .invalid_value, .option = display(o), .value = bytes, .expected = expected, .env = env, .suggestion = suggestion });
        }

        fn append(self: *Self, st: *State, comptime o: model.Opt, bytes: []const u8, env: ?[]const u8) Error!void {
            const list = &@field(self.lists, o.field);
            if (o.meta.delimiter) |d| {
                var parts = std.mem.splitScalar(u8, bytes, d);
                while (parts.next()) |part| try list.append(st.gpa, try one(st, o, part, env));
            } else try list.append(st.gpa, try one(st, o, bytes, env));
        }

        /// How help and messages spell an option.
        fn display(comptime o: model.Opt) []const u8 {
            return if (o.positional) help.positional(o) else "--" ++ o.long;
        }

        fn positionalArg(self: *Self, st: *State, arg: []const u8) Error!void {
            const n = info.positionals.len;
            if (n == 0) return unexpectedArgument(st, arg) else return self.positionalAt(st, arg);
        }

        fn positionalAt(self: *Self, st: *State, arg: []const u8) Error!void {
            const n = info.positionals.len;
            if (self.positional >= n and info.positionals[n - 1].kind != .list) return unexpectedArgument(st, arg);
            const at: usize = @min(self.positional, n - 1);
            switch (at) {
                inline 0...n - 1 => |i| {
                    const p = info.positionals[i];
                    if (p.kind == .list) {
                        try self.append(st, p, arg, null);
                    } else {
                        @field(self.out, p.field) = try one(st, p, arg, null);
                        self.positional += 1;
                    }
                },
                else => unreachable, // unreachable: the index was clamped below the positional count
            }
        }

        fn unexpectedArgument(st: *State, arg: []const u8) Error {
            return st.fail(error.UnexpectedArgument, .{ .problem = .unexpected_argument, .argument = arg });
        }

        fn command(self: *Self, st: *State, cursor: anytype, arg: []const u8) (Error || Request)!void {
            const c = info.commands.?;
            const index = subs.get(arg) orelse {
                var nearest: text.Nearest = .{ .typed = arg };
                inline for (c.list) |sub| if (!sub.meta.hidden) {
                    inline for (.{sub.name} ++ sub.aliases) |name| nearest.consider(name);
                };
                return st.fail(error.UnknownCommand, .{ .problem = .unknown_command, .argument = arg, .suggestion = nearest.best });
            };
            switch (index) {
                inline 0...c.list.len - 1 => |i| {
                    const sub = c.list[i];
                    const P = if (sub.Payload == void) Bare(sub.meta.help) else sub.Payload;
                    var payload: P = defaults(P);
                    var child: Frame(chain ++ .{P}, names ++ .{sub.name}, Self) = .{ .out = &payload, .parent = self };
                    try child.run(st, cursor);
                    @field(self.out, c.field) = @unionInit(c.Union, sub.tag, if (sub.Payload == void) {} else payload);
                    self.chose = true;
                },
                else => unreachable, // unreachable: the table holds only this command's variants
            }
        }

        fn releaseCommand(self: *Self, st: *State) void {
            freeCommand(C, st.gpa, self.out);
        }

        /// What is left when the arguments end: lists, the environment,
        /// and what was required.
        fn finish(self: *Self, st: *State) Error!void {
            st.page = &Pg.page;
            errdefer self.release(st);
            inline for (info.options ++ info.positionals) |o| {
                if (o.kind == .list and @field(self.lists, o.field).items.len != 0) {
                    @field(self.out, o.field) = try @field(self.lists, o.field).toOwnedSlice(st.gpa);
                    self.owned.set(slot(o));
                    if (!o.positional) self.given.set(o.index);
                }
            }
            try self.conflicts(st);
            if (st.environ) |environ| inline for (info.options) |o| {
                if (o.meta.env) |name| if (!self.seen.isSet(o.index) and !self.silenced(o)) {
                    if (environ.get(name)) |bytes| if (bytes.len != 0) try self.fromEnv(st, o, name, bytes);
                };
            };
            inline for (info.options) |o| {
                if (o.required and !self.given.isSet(o.index))
                    return st.fail(error.MissingOption, .{ .problem = .missing_option, .option = "--" ++ o.long ++ " <" ++ o.value_name ++ ">", .env = o.meta.env });
            }
            inline for (info.positionals, 0..) |p, i| {
                const has = if (p.kind == .list) self.owned.isSet(slot(p)) else self.positional > i;
                if (p.required and !has) return st.fail(error.MissingArgument, .{ .problem = .missing_argument, .option = help.positional(p) });
            }
            if (info.commands) |c| if (!c.optional and !self.chose)
                return st.fail(error.MissingCommand, .{ .problem = .missing_command, .expected = comptime commandList(c) });
        }

        fn slot(comptime o: model.Opt) usize {
            return if (o.positional) n_options + o.index else o.index;
        }

        fn release(self: *Self, st: *State) void {
            inline for (info.options ++ info.positionals) |o| {
                if (o.kind == .list and self.owned.isSet(slot(o))) st.gpa.free(@field(self.out, o.field));
            }
        }

        /// Whether the command line gave an option that conflicts with `o`.
        fn silenced(self: *Self, comptime o: model.Opt) bool {
            inline for (s.conflicts) |group| {
                const member = comptime for (group) |f| {
                    if (std.mem.eql(u8, @tagName(f), o.field)) break true;
                } else false;
                if (member) inline for (group) |f| {
                    if (self.seen.isSet(comptime indexOf(@tagName(f)))) return true;
                };
            }
            return false;
        }

        fn indexOf(comptime field: []const u8) usize {
            @setEvalBranchQuota(text.branch_quota);
            for (info.options) |o| {
                if (std.mem.eql(u8, o.field, field)) return o.index;
            }
            unreachable; // unreachable: model.validate checked that conflicts name options
        }

        fn conflicts(self: *Self, st: *State) Error!void {
            inline for (s.conflicts) |group| {
                var first: ?[]const u8 = null;
                inline for (group) |f| {
                    const o = info.options[comptime indexOf(@tagName(f))];
                    if (self.seen.isSet(o.index)) {
                        if (first) |other| return st.fail(error.Conflict, .{ .problem = .conflict, .option = other, .other = "--" ++ o.long });
                        first = "--" ++ o.long;
                    }
                }
            }
        }

        fn fromEnv(self: *Self, st: *State, comptime o: model.Opt, name: []const u8, bytes: []const u8) Error!void {
            switch (o.kind) {
                .flag => @field(self.out, o.field) = value.boolean(bytes) orelse return invalid(st, o, bytes, name),
                .count => @field(self.out, o.field) = value.parse(o.Field, bytes) orelse return invalid(st, o, bytes, name),
                .single => @field(self.out, o.field) = try one(st, o, bytes, name),
                .list => {
                    try self.append(st, o, bytes, name);
                    @field(self.out, o.field) = try @field(self.lists, o.field).toOwnedSlice(st.gpa);
                    self.owned.set(slot(o));
                },
            }
            self.given.set(o.index);
        }

        fn commandList(comptime c: model.Subs) []const u8 {
            @setEvalBranchQuota(text.branch_quota);
            var out: []const u8 = "one of ";
            var first = true;
            for (c.list) |sub| {
                if (sub.meta.hidden) continue;
                out = out ++ (if (first) "" else ", ") ++ sub.name;
                first = false;
            }
            return out;
        }
    };
}

/// The arguments of a subcommand that has none: only its help line.
fn Bare(comptime about: []const u8) type {
    return struct {
        pub const spec: @import("spec.zig").Spec(@This()) = .{ .about = about };
    };
}
