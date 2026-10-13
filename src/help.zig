//! Usage lines and help pages, generated from the declaration and wrapped
//! to a width.
const std = @import("std");
const model = @import("model.zig");
const spec = @import("spec.zig");
const text = @import("text.zig");
const value = @import("value.zig");
const Page = @import("diagnostic.zig").Page;
const Writer = std.Io.Writer;

/// The narrowest width help is wrapped to.
pub const min_width = 40;

/// The page of the command reached by `chain`, a list of command types from
/// the root down, whose subcommand names below the root are `names`.
pub fn Pages(comptime chain: []const type, comptime names: []const []const u8) type {
    return struct {
        const info = model.info(chain[chain.len - 1]);
        const s = info.specOf();

        pub const page: Page = .{
            .path = join(names),
            .help_flag = if (s.help) |f| f.long else null,
            .writeUsage = writeUsage,
            .writeHelp = writeHelp,
        };

        fn writeUsage(w: *Writer, program: []const u8, width: usize) Writer.Error!void {
            try w.writeAll("Usage: ");
            try page.writeName(w, program);
            var col = 7 + text.width(program) + (if (page.path.len == 0) 0 else 1 + page.path.len);
            const indent = @min(col + 1, 24);
            inline for (comptime usageWords(info)) |word| {
                col = try text.wrap(w, word, indent, col, @max(width, min_width));
            }
            try w.writeByte('\n');
        }

        fn writeHelp(w: *Writer, program: []const u8, width_asked: usize) Writer.Error!void {
            const width = @max(width_asked, min_width);
            if (s.about.len != 0) {
                _ = try text.wrap(w, s.about, 0, 0, width);
                try w.writeAll("\n\n");
            }
            try writeUsage(w, program, width);
            if (s.description.len != 0) {
                try w.writeByte('\n');
                _ = try text.wrap(w, s.description, 0, 0, width);
                try w.writeByte('\n');
            }
            const rows = comptime pageRows(chain);
            const column = comptime descriptionColumn(rows, 0);
            // Each block's rows, laid out against the widest left column of the page.
            inline for (comptime blocks(rows)) |heading| {
                try w.print("\n{s}:\n", .{heading});
                inline for (rows) |row| {
                    if (comptime std.mem.eql(u8, row.heading, heading)) try writeRow(w, row, column, width);
                }
            }
            if (s.examples.len != 0) {
                try w.writeAll("\nExamples:\n");
                for (s.examples) |example| {
                    _ = try text.wrap(w, example.command, 2, 0, width);
                    try w.writeByte('\n');
                    if (example.help.len != 0) {
                        _ = try text.wrap(w, example.help, 6, 0, width);
                        try w.writeByte('\n');
                    }
                }
            }
            for (s.sections) |section| {
                try w.print("\n{s}:\n", .{section.heading});
                _ = try text.wrap(w, section.body, 2, 0, width);
                try w.writeByte('\n');
            }
        }
    };
}

/// A line of a help block: the names on the left, the words on the right.
const Row = struct {
    heading: []const u8,
    left: []const u8,
    description: []const u8,
};

fn writeRow(w: *Writer, comptime row: Row, column_cap: usize, width: usize) Writer.Error!void {
    // Narrow terminals take a narrower left column.
    const column = @min(column_cap, width / 2);
    const left = comptime text.width(row.left);
    try w.writeAll(row.left);
    var col: usize = left;
    if (row.description.len == 0) {
        try w.writeByte('\n');
        return;
    }
    if (left + 2 > column) {
        try w.writeByte('\n');
        col = 0;
    }
    _ = try text.wrap(w, row.description, column, col, width);
    try w.writeByte('\n');
}

/// The column descriptions start at: past the widest left column, but
/// never past 32 + 2.
fn descriptionColumn(comptime rows: []const Row, comptime floor: usize) usize {
    @setEvalBranchQuota(text.branch_quota);
    var widest: usize = floor;
    for (rows) |row| {
        const wide = text.width(row.left);
        if (wide <= 32) widest = @max(widest, wide);
    }
    return widest + 2;
}

fn blocks(comptime rows: []const Row) []const []const u8 {
    @setEvalBranchQuota(text.branch_quota);
    var out: []const []const u8 = &.{};
    for (rows) |row| {
        const seen = for (out) |h| {
            if (std.mem.eql(u8, h, row.heading)) break true;
        } else false;
        if (!seen) out = out ++ .{row.heading};
    }
    return out;
}

/// Every row of a command's page, in order: commands, arguments, options
/// by section with the built-in flags last of "Options", then the global
/// options of the commands above.
fn pageRows(comptime chain: []const type) []const Row {
    @setEvalBranchQuota(text.branch_quota);
    const info = model.info(chain[chain.len - 1]);
    var rows: []const Row = &.{};
    if (info.commands) |c| for (c.list) |sub| {
        if (sub.meta.hidden) continue;
        var left: []const u8 = "  " ++ sub.name;
        for (sub.aliases) |alias| left = left ++ ", " ++ alias;
        rows = rows ++ .{Row{ .heading = "Commands", .left = left, .description = commandLine(sub) }};
    };
    for (info.positionals) |p| {
        if (p.meta.hidden) continue;
        rows = rows ++ .{Row{ .heading = "Arguments", .left = "  " ++ positional(p), .description = describe(p) }};
    }
    for (info.options) |o| {
        if (o.meta.hidden) continue;
        rows = rows ++ .{Row{ .heading = o.meta.section orelse "Options", .left = optionLeft(o), .description = describe(o) }};
    }
    const s = info.specOf();
    if (s.help) |f| rows = rows ++ .{Row{ .heading = "Options", .left = flagLeft(f), .description = "Print help" }};
    if (info.version()) |f| rows = rows ++ .{Row{ .heading = "Options", .left = flagLeft(f), .description = "Print the version" }};
    for (chain[0 .. chain.len - 1]) |Above| {
        for (model.info(Above).globals()) |g| {
            if (g.meta.hidden) continue;
            rows = rows ++ .{Row{ .heading = "Global options", .left = optionLeft(g), .description = describe(g) }};
        }
    }
    return rows;
}

fn commandLine(comptime sub: model.Sub) []const u8 {
    if (sub.meta.help.len != 0) return sub.meta.help;
    if (sub.Payload == void) return "";
    const about = model.info(sub.Payload).specOf().about;
    return about[0 .. std.mem.findScalar(u8, about, '\n') orelse about.len];
}

fn flagLeft(comptime f: spec.Flag) []const u8 {
    return (if (f.short) |c| "  -" ++ .{c} ++ ", " else "      ") ++ "--" ++ f.long;
}

fn optionLeft(comptime o: model.Opt) []const u8 {
    const short = if (o.short) |c| "  -" ++ .{c} ++ ", " else "      ";
    const long = if (o.shows_negation) "--[no-]" ++ o.long else "--" ++ o.long;
    const after = switch (o.kind) {
        .flag => "",
        .count => "...",
        .single => " <" ++ o.value_name ++ ">",
        .list => " <" ++ o.value_name ++ ">...",
    };
    return short ++ long ++ after;
}

/// `<NAME>`, `[NAME]`, `<NAME>...` or `[NAME]...`.
pub fn positional(comptime p: model.Opt) []const u8 {
    const name = if (p.required) "<" ++ p.value_name ++ ">" else "[" ++ p.value_name ++ "]";
    return if (p.kind == .list) name ++ "..." else name;
}

/// An option's help with what else a reader needs: its default, its
/// variable and its possible values.
fn describe(comptime o: model.Opt) []const u8 {
    var out: []const u8 = o.meta.help;
    if (defaultText(o)) |d| out = out ++ (if (out.len == 0) "" else " ") ++ "[default:" ++ text.glue ++ d ++ "]";
    if (o.meta.env) |name| out = out ++ (if (out.len == 0) "" else " ") ++ "[env:" ++ text.glue ++ name ++ "]";
    if (@typeInfo(o.Value) == .@"enum" and o.kind != .count) {
        var values: []const u8 = "";
        for (value.names(o.Value), 0..) |name, n| values = values ++ (if (n == 0) "" else ", ") ++ name;
        out = out ++ (if (out.len == 0) "" else " ") ++ "[possible" ++ text.glue ++ "values:" ++ text.glue ++ values ++ "]";
    }
    return out;
}

/// A default worth showing: not false, zero, null or empty.
fn defaultText(comptime o: model.Opt) ?[]const u8 {
    if (o.required) return null;
    const d = o.default() orelse return null;
    return switch (o.kind) {
        .flag, .count => null,
        .single => if (o.optional) (if (d) |v| one(o.Value, v) else null) else one(o.Value, d),
        .list => blk: {
            if (d.len == 0) break :blk null;
            var out: []const u8 = "";
            for (d, 0..) |v, n| out = out ++ (if (n == 0) "" else ", ") ++ one(o.Value, v);
            break :blk out;
        },
    };
}

fn one(comptime V: type, comptime v: V) []const u8 {
    return switch (@typeInfo(V)) {
        .int => std.fmt.comptimePrint("{d}", .{v}),
        .float => std.fmt.comptimePrint("{d}", .{v}),
        .@"enum" => value.names(V)[value.enumIndex(V, v)],
        .pointer => v,
        else => @compileError("ensign: no default text for " ++ @typeName(V)),
    };
}

/// The words after the command's name on its usage line.
fn usageWords(comptime i: model.Info) []const []const u8 {
    @setEvalBranchQuota(text.branch_quota);
    var words: []const []const u8 = &.{};
    var optional = model.builtins(i).len != 0;
    for (i.options) |o| {
        if (o.meta.hidden) continue;
        if (o.required) {
            words = words ++ .{"--" ++ o.long ++ text.glue ++ "<" ++ o.value_name ++ ">" ++ (if (o.kind == .list) "..." else "")};
        } else optional = true;
    }
    if (optional) words = .{"[options]"} ++ words;
    if (i.commands) |c| words = words ++ .{if (c.optional) "[command]" else "<command>"};
    for (i.positionals) |p| words = words ++ .{positional(p)};
    return words;
}

fn join(comptime names: []const []const u8) []const u8 {
    var out: []const u8 = "";
    for (names, 0..) |name, n| out = out ++ (if (n == 0) "" else " ") ++ name;
    return out;
}
