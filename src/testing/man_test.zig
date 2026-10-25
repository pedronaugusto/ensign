//! Manual pages: each command's page word for word, every page clean under
//! mandoc's lint where mandoc is installed, and its rendering holding what
//! help holds.
const std = @import("std");
const ensign = @import("../ensign.zig");

const Color = enum { auto, always, never };

const Build = struct {
    release: bool = false,
    jobs: u16 = 0,
    target: ?[]const u8 = null,
    key: ?[]const u8 = null,
    cert: ?[]const u8 = null,
    files: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Build the project",
        .description = "Builds every file given.\n\n.dotted lines and 'quoted ones stay text.",
        .options = .{
            .release = .{ .short = 'r', .help = "Optimize for speed" },
            .jobs = .{ .short = 'j', .env = "TOOL_JOBS", .help = "Parallel jobs" },
            .target = .{ .value_name = "TRIPLE", .help = "The target, as x86_64-linux" },
            .key = .{ .section = "TLS", .help = "The private key" },
            .cert = .{ .section = "TLS", .help = "The certificate" },
            .files = .{ .positional = true, .help = "Files to build" },
        },
        .requires = &.{.{ .option = .key, .needs = &.{.cert} }},
        .examples = &.{.{ .command = "tool build -rj8 main.zig", .help = "Build one file for speed." }},
    };
};

const Tool = struct {
    verbose: u8 = 0,
    color: Color = .auto,
    command: union(enum) { build: Build, clean },
    pub const spec: ensign.Spec(@This()) = .{
        .name = "tool",
        .version = "1.2.0",
        .about = "Build things \\ with a backslash",
        .options = .{
            .verbose = .{ .short = 'v', .count = true, .global = true, .help = "Say more" },
            .color = .{ .global = true, .env = "TOOL_COLOR", .help = "When to colour" },
        },
        .commands = .{ .build = .{ .aliases = &.{"b"} }, .clean = .{ .help = "Remove what was built" } },
        .sections = &.{.{ .heading = "Exit status", .body = "0 on success, 2 for a mistake." }},
    };
};

fn page(command: []const []const u8, out: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(out);
    try ensign.writeManPage(Tool, &w, .{ .date = "2026-10-25", .manual = "User Commands", .command = command });
    return w.buffered();
}

test "a subcommand's page, word for word" {
    var buffer: [8192]u8 = undefined;
    try std.testing.expectEqualStrings(
        \\.TH "TOOL\-BUILD" "1" "2026-10-25" "tool 1.2.0" "User Commands"
        \\.SH NAME
        \\tool\-build \- Build the project
        \\.SH SYNOPSIS
        \\.B tool build
        \\[options]
        \\[FILES]...
        \\.SH DESCRIPTION
        \\Builds every file given.
        \\.sp
        \\\&.dotted lines and 'quoted ones stay text.
        \\.SH "ARGUMENTS"
        \\.TP
        \\\fI[FILES]...\fR
        \\Files to build
        \\.SH "OPTIONS"
        \\.TP
        \\\fB\-r\fR, \fB\-\-release\fR
        \\Optimize for speed
        \\.TP
        \\\fB\-j\fR, \fB\-\-jobs\fR \fI<JOBS>\fR
        \\Parallel jobs [default:\ 0] [env:\ TOOL_JOBS]
        \\.TP
        \\\fB\-\-target\fR \fI<TRIPLE>\fR
        \\The target, as x86_64\-linux
        \\.TP
        \\\fB\-h\fR, \fB\-\-help\fR
        \\Print help
        \\.SH "TLS"
        \\.TP
        \\\fB\-\-key\fR \fI<KEY>\fR
        \\The private key [requires:\ \-\-cert]
        \\.TP
        \\\fB\-\-cert\fR \fI<CERT>\fR
        \\The certificate
        \\.SH "GLOBAL OPTIONS"
        \\.TP
        \\\fB\-v\fR, \fB\-\-verbose\fR...
        \\Say more
        \\.TP
        \\\fB\-\-color\fR \fI<COLOR>\fR
        \\When to colour [default:\ auto] [env:\ TOOL_COLOR] [possible\ values:\ auto,
        \\always, never]
        \\.SH ENVIRONMENT
        \\.TP
        \\.B TOOL_COLOR
        \\Sets \fB\-\-color\fR when the command line does not give it.
        \\.TP
        \\.B TOOL_JOBS
        \\Sets \fB\-\-jobs\fR when the command line does not give it.
        \\.SH EXAMPLES
        \\.TP
        \\.B tool build \-rj8 main.zig
        \\Build one file for speed.
        \\.SH "SEE ALSO"
        \\\fBtool\fR(1)
        \\
    , try page(&.{"build"}, &buffer));
}

test "the root's page names its commands, sections, version and the pages below" {
    var buffer: [8192]u8 = undefined;
    const root = try page(&.{}, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, root, ".TH \"TOOL\" \"1\" \"2026-10-25\" \"tool 1.2.0\" \"User Commands\"\n.SH NAME\ntool \\- Build things \\e with a backslash\n"));
    try std.testing.expect(std.mem.find(u8, root, ".SH \"EXIT STATUS\"\n0 on success, 2 for a mistake.\n") != null);
    try std.testing.expect(std.mem.find(u8, root, ".SH VERSION\n1.2.0\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, root, ".SH \"SEE ALSO\"\n\\fBtool\\-build\\fR(1)\n"));
    try std.testing.expectError(error.UnknownCommand, page(&.{"clean"}, &buffer));
    try std.testing.expectError(error.UnknownCommand, page(&.{"nothing"}, &buffer));
}

test "every command is listed, the root first" {
    const all = ensign.commands(Tool);
    try std.testing.expectEqual(2, all.len);
    try std.testing.expectEqual(0, all[0].len);
    try std.testing.expectEqualStrings("build", all[1][0]);
}

/// Runs mandoc on `source`; null when mandoc is not installed.
fn mandoc(args: []const []const u8, source: []const u8) !?[]u8 {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "page.1", .data = source });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "mandoc");
    try argv.appendSlice(gpa, args);
    try argv.append(gpa, "page.1");
    const result = std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .path = dir } }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    if (result.stderr.len != 0) {
        std.debug.print("mandoc {s}:\n{s}\n", .{ args[0], result.stderr });
        return error.MandocComplained;
    }
    return result.stdout;
}

test "every page is clean under mandoc's lint, at every level" {
    var buffer: [8192]u8 = undefined;
    for (ensign.commands(Tool)) |command| {
        const out = try mandoc(&.{ "-T", "lint", "-W", "all" }, try page(command, &buffer)) orelse return error.SkipZigTest;
        std.testing.allocator.free(out);
    }
}

test "mandoc renders what help holds" {
    var buffer: [8192]u8 = undefined;
    const out = try mandoc(&.{ "-T", "ascii", "-O", "width=200" }, try page(&.{"build"}, &buffer)) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(std.testing.allocator);
    // Overstrike: `c\bc` is bold, `_\bc` underlined; keep the character.
    var k: usize = 0;
    while (k < out.len) : (k += 1) {
        if (k + 2 < out.len and out[k + 1] == 0x08) {
            try plain.append(std.testing.allocator, out[k + 2]);
            k += 2;
        } else try plain.append(std.testing.allocator, out[k]);
    }
    for ([_][]const u8{ "tool-build - Build the project", "tool build [options] [FILES]...", "-j, --jobs <JOBS>", "Parallel jobs [default: 0] [env: TOOL_JOBS]", ".dotted lines and 'quoted ones stay text.", "The private key [requires: --cert]", "When to colour [default: auto] [env: TOOL_COLOR] [possible values: auto, always, never]", "tool(1)" }) |want| {
        if (std.mem.find(u8, plain.items, want) == null) {
            std.debug.print("rendered page lacks '{s}':\n{s}\n", .{ want, plain.items });
            return error.TestUnexpectedResult;
        }
    }
}
