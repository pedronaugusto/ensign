//! Manual pages, generated from the declaration: roff with the man(7)
//! macros, one page a command, read by mandoc and groff alike. The page
//! holds what help holds, laid out as a manual's sections.
const std = @import("std");
const model = @import("model.zig");
const spec = @import("spec.zig");
const text = @import("text.zig");
const help = @import("help.zig");
const Writer = std.Io.Writer;

/// What a page's header and footer say, and which command it is of.
pub const ManOptions = struct {
    /// The program's name; the declaration's `name` when null, then "program".
    name: ?[]const u8 = null,
    /// The manual section: "1" for commands, "8" for administration.
    section: []const u8 = "1",
    /// The date in the footer, as the program shows it: `2026-10-25`.
    date: []const u8 = "",
    /// The footer's left side: the package and its version. The
    /// declaration's name and version when empty.
    source: []const u8 = "",
    /// The header's middle: the manual's title, such as "User Commands".
    manual: []const u8 = "",
    /// The subcommand names from the root down; empty for the root's page.
    command: []const []const u8 = &.{},
};

pub const ManError = Writer.Error || error{
    /// `command` names no command of the declaration.
    UnknownCommand,
};

/// Writes the manual page of the command of `T` at `options.command`.
pub fn writeManPage(comptime T: type, w: *Writer, options: ManOptions) ManError!void {
    const program = options.name orelse model.declared(T).name orelse "program";
    inline for (comptime walk(T, &.{T}, &.{})) |page| {
        if (matches(page.names, options.command)) return page.write(w, program, options);
    }
    return error.UnknownCommand;
}

/// Every command of `T`'s tree as its subcommand names from the root, the
/// root first: the pages a program writes, `prog.1`, `prog-build.1`.
pub fn commands(comptime T: type) []const []const []const u8 {
    const out = comptime blk: {
        @setEvalBranchQuota(text.branch_quota);
        var list: []const []const []const u8 = &.{};
        for (walk(T, &.{T}, &.{})) |page| list = list ++ .{page.names};
        break :blk list;
    };
    return out;
}

fn matches(names: []const []const u8, asked: []const []const u8) bool {
    if (names.len != asked.len) return false;
    for (names, asked) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

const Entry = struct {
    names: []const []const u8,
    write: *const fn (w: *Writer, program: []const u8, options: ManOptions) Writer.Error!void,
};

fn walk(comptime T: type, comptime chain: []const type, comptime names: []const []const u8) []const Entry {
    @setEvalBranchQuota(text.branch_quota);
    const i = model.info(T);
    var out: []const Entry = &.{.{ .names = names, .write = Page(chain, names).write }};
    if (i.commands) |c| for (c.list) |sub| {
        if (sub.external or sub.Payload == void) continue;
        out = out ++ walk(sub.Payload, chain ++ .{sub.Payload}, names ++ .{sub.name});
    };
    return out;
}

/// The page of the command `chain` reaches, named `names` below the root.
fn Page(comptime chain: []const type, comptime names: []const []const u8) type {
    return struct {
        const info = model.info(chain[chain.len - 1]);
        const s = info.specOf();

        fn write(w: *Writer, program: []const u8, options: ManOptions) Writer.Error!void {
            try w.writeAll(".TH \"");
            try upper(w, program);
            inline for (names) |name| {
                try w.writeAll("\\-");
                try upper(w, name);
            }
            try w.writeAll("\" \"");
            try argument(w, options.section);
            try w.writeAll("\" \"");
            try argument(w, options.date);
            try w.writeAll("\" \"");
            const root = model.declared(chain[0]);
            if (options.source.len != 0) {
                try argument(w, options.source);
            } else {
                try argument(w, root.name orelse program);
                if (root.version) |v| {
                    try w.writeByte(' ');
                    try argument(w, v);
                }
            }
            try w.writeAll("\" \"");
            try argument(w, options.manual);
            try w.writeAll("\"\n");

            try w.writeAll(".SH NAME\n");
            try pageName(w, program, "\\-");
            if (s.about.len != 0) {
                try w.writeAll(" \\- ");
                try inlineText(w, s.about);
            }
            try w.writeAll("\n.SH SYNOPSIS\n.B ");
            try pageName(w, program, " ");
            try w.writeByte('\n');
            inline for (comptime synopsis()) |word| {
                try inlineText(w, word);
                try w.writeByte('\n');
            }
            if (s.description.len != 0) {
                try w.writeAll(".SH DESCRIPTION\n");
                try body(w, s.description);
            }
            const rows = comptime pageRows();
            inline for (comptime headings(rows)) |heading| {
                try w.writeAll(".SH ");
                try sectionName(w, heading);
                inline for (rows) |row| {
                    if (comptime std.mem.eql(u8, row.heading, heading)) {
                        try w.writeAll(".TP\n");
                        try w.writeAll(row.term);
                        try w.writeByte('\n');
                        if (row.description.len != 0) try body(w, row.description);
                    }
                }
            }
            const variables = comptime environment();
            if (variables.len != 0) {
                try w.writeAll(".SH ENVIRONMENT\n");
                inline for (variables) |v| {
                    try w.writeAll(".TP\n.B ");
                    try inlineText(w, v.name);
                    try w.writeAll("\nSets \\fB\\-\\-");
                    try inlineText(w, v.option);
                    try w.writeAll("\\fR when the command line does not give it.\n");
                }
            }
            if (s.examples.len != 0) {
                try w.writeAll(".SH EXAMPLES\n");
                for (s.examples) |example| {
                    try w.writeAll(".TP\n.B ");
                    try inlineText(w, example.command);
                    try w.writeByte('\n');
                    if (example.help.len != 0) try body(w, example.help);
                }
            }
            for (s.sections) |section| {
                try w.writeAll(".SH ");
                try sectionName(w, section.heading);
                try body(w, section.body);
            }
            if (root.version) |v| if (names.len == 0) {
                try w.writeAll(".SH VERSION\n");
                try body(w, v);
            };
            const related = comptime seeAlso();
            if (related.len != 0) {
                try w.writeAll(".SH \"SEE ALSO\"\n");
                inline for (related, 0..) |path, n| {
                    try w.writeAll("\\fB");
                    try escaped(w, program);
                    inline for (path) |name| {
                        try w.writeAll("\\-");
                        try escaped(w, name);
                    }
                    try w.writeAll("\\fR(");
                    try escaped(w, options.section);
                    try w.writeAll(if (n + 1 == related.len) ")\n" else "),\n");
                }
            }
        }

        /// `prog`, then the subcommand names, joined by `separator`.
        fn pageName(w: *Writer, program: []const u8, comptime separator: []const u8) Writer.Error!void {
            try escaped(w, program);
            inline for (names) |name| {
                try w.writeAll(separator);
                try escaped(w, name);
            }
        }

        /// The usage line's words after the command's name, each a line,
        /// the names bold and the values italic.
        fn synopsis() []const []const u8 {
            @setEvalBranchQuota(text.branch_quota);
            var out: []const []const u8 = &.{};
            for (help.usageWords(info)) |word| out = out ++ .{word};
            return out;
        }

        const Row = struct { heading: []const u8, term: []const u8, description: []const u8 };

        /// Commands, arguments, options by section and the global options
        /// of the commands above, each with its term already in roff.
        fn pageRows() []const Row {
            @setEvalBranchQuota(text.branch_quota);
            var rows: []const Row = &.{};
            if (info.commands) |c| for (c.list) |sub| {
                if (sub.meta.hidden) continue;
                var term: []const u8 = "\\fB" ++ roff(sub.name) ++ "\\fR";
                for (sub.aliases) |alias| term = term ++ ", \\fB" ++ roff(alias) ++ "\\fR";
                rows = rows ++ .{Row{ .heading = "Commands", .term = term, .description = help.commandLine(sub) }};
            };
            for (info.positionals) |p| {
                if (p.meta.hidden) continue;
                rows = rows ++ .{Row{ .heading = "Arguments", .term = "\\fI" ++ roff(help.positional(p)) ++ "\\fR", .description = help.describe(info, p) }};
            }
            for (info.options) |o| {
                if (o.meta.hidden) continue;
                rows = rows ++ .{Row{ .heading = o.meta.section orelse "Options", .term = optionTerm(o), .description = help.describe(info, o) }};
            }
            if (s.help) |f| rows = rows ++ .{Row{ .heading = "Options", .term = flagTerm(f), .description = "Print help" }};
            if (info.version()) |f| rows = rows ++ .{Row{ .heading = "Options", .term = flagTerm(f), .description = "Print the version" }};
            for (chain[0 .. chain.len - 1]) |Above| {
                const above = model.info(Above);
                for (above.globals()) |g| {
                    if (g.meta.hidden) continue;
                    rows = rows ++ .{Row{ .heading = "Global options", .term = optionTerm(g), .description = help.describe(above, g) }};
                }
            }
            return rows;
        }

        fn headings(comptime rows: []const Row) []const []const u8 {
            var out: []const []const u8 = &.{};
            for (rows) |row| {
                const seen = for (out) |h| {
                    if (std.mem.eql(u8, h, row.heading)) break true;
                } else false;
                if (!seen) out = out ++ .{row.heading};
            }
            return out;
        }

        fn optionTerm(comptime o: model.Opt) []const u8 {
            var term: []const u8 = if (o.short) |c| "\\fB\\-" ++ roff(&.{c}) ++ "\\fR, " else "";
            term = term ++ "\\fB\\-\\-" ++ (if (o.shows_negation) "[no\\-]" else "") ++ roff(o.long) ++ "\\fR";
            for (o.aliases) |alias| term = term ++ ", \\fB\\-\\-" ++ roff(alias) ++ "\\fR";
            return term ++ switch (o.kind) {
                .flag => "",
                .count => "...",
                .single => " \\fI<" ++ roff(o.value_name) ++ ">\\fR",
                .list => " \\fI<" ++ roff(o.value_name) ++ ">\\fR...",
            };
        }

        fn flagTerm(comptime f: spec.Flag) []const u8 {
            return (if (f.short) |c| "\\fB\\-" ++ roff(&.{c}) ++ "\\fR, " else "") ++ "\\fB\\-\\-" ++ roff(f.long) ++ "\\fR";
        }

        const Variable = struct { name: []const u8, option: []const u8 };

        /// Every variable this command's options and the globals above read.
        fn environment() []const Variable {
            @setEvalBranchQuota(text.branch_quota);
            var out: []const Variable = &.{};
            for (chain, 0..) |C, n| {
                const c = model.info(C);
                const options = if (n + 1 == chain.len) c.options else c.globals();
                for (options) |o| if (o.meta.env) |name| if (!o.meta.hidden) {
                    out = out ++ .{Variable{ .name = name, .option = o.long }};
                };
            }
            return out;
        }

        /// The parent's page and each subcommand's.
        fn seeAlso() []const []const []const u8 {
            @setEvalBranchQuota(text.branch_quota);
            var out: []const []const []const u8 = &.{};
            if (names.len != 0) out = out ++ .{names[0 .. names.len - 1]};
            if (info.commands) |c| for (c.list) |sub| {
                if (sub.meta.hidden or sub.external or sub.Payload == void) continue;
                out = out ++ .{names ++ .{sub.name}};
            };
            return out;
        }
    };
}

/// `bytes` escaped for roff at compile time.
fn roff(comptime bytes: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (bytes) |c| out = out ++ switch (c) {
            '\\' => "\\e",
            '-' => "\\-",
            text.glue[0] => "\\ ",
            else => &[_]u8{c},
        };
        return out;
    }
}

/// Writes text inside a line: `\` as `\e`, `-` as `\-` so that it stays a
/// hyphen-minus a reader can search and copy, and glue as an unbreakable
/// space. UTF-8 passes as it is.
fn escaped(w: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |c| switch (c) {
        '\\' => try w.writeAll("\\e"),
        '-' => try w.writeAll("\\-"),
        text.glue[0] => try w.writeAll("\\ "),
        else => try w.writeByte(c),
    };
}

/// As `escaped`, for text that may hold line breaks, which become spaces.
fn inlineText(w: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |c| switch (c) {
        '\n' => try w.writeByte(' '),
        else => try escaped(w, &.{c}),
    };
}

/// A macro's quoted argument: a `"` inside it as `\(dq`. A `-` stays as
/// it is, so that mandoc reads a date such as `2026-10-25` as one.
fn argument(w: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |c| switch (c) {
        '"' => try w.writeAll("\\(dq"),
        '\\' => try w.writeAll("\\e"),
        '\n' => try w.writeByte(' '),
        else => try w.writeByte(c),
    };
}

/// A section's heading in capitals, quoted.
fn sectionName(w: *Writer, heading: []const u8) Writer.Error!void {
    try w.writeByte('"');
    try upper(w, heading);
    try w.writeAll("\"\n");
}

fn upper(w: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |c| switch (c) {
        '"' => try w.writeAll("\\(dq"),
        else => try escaped(w, &.{std.ascii.toUpper(c)}),
    };
}

/// Text in fill mode: a line break as `.br`, an empty line as `.sp`, and a
/// line that would start with `.` or `'`, which roff reads as a request,
/// guarded by `\&`.
fn body(w: *Writer, bytes: []const u8) Writer.Error!void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var before: enum { start, text, gap } = .start;
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (before == .text) try w.writeAll(".sp\n");
            before = .gap;
            continue;
        }
        if (before == .text) try w.writeAll(".br\n");
        before = .text;
        // Source lines kept to 80 bytes, broken at spaces, which fill mode joins.
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        var column: usize = 0;
        while (words.next()) |word| {
            const wide = escapedLen(word);
            if (column != 0 and column + 1 + wide > 80) {
                try w.writeByte('\n');
                column = 0;
            } else if (column != 0) {
                try w.writeByte(' ');
                column += 1;
            }
            if (column == 0 and (word[0] == '.' or word[0] == '\'')) {
                try w.writeAll("\\&");
                column += 2;
            }
            try escaped(w, word);
            column += wide;
        }
        try w.writeByte('\n');
    }
}

/// The bytes `escaped` writes for `bytes`.
fn escapedLen(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |c| n += if (c == '\\' or c == '-' or c == text.glue[0]) 2 else 1;
    return n;
}

test "roff escapes" {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try body(&w, ".hidden\n'quoted\n\nback\\slash -x " ++ text.glue ++ "y");
    try std.testing.expectEqualStrings("\\&.hidden\n.br\n\\&'quoted\n.sp\nback\\eslash \\-x \\ y\n", w.buffered());
}
