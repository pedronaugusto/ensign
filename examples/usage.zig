//! A program's arguments declared once: `usage --help`, `usage build --help`
//! and `usage completions bash` show what the declaration generates.
const std = @import("std");
const ensign = @import("ensign");

// --- README:declare ---
const Build = struct {
    release: bool = false,
    jobs: u16 = 0,
    target: ?[]const u8 = null,
    files: []const []const u8 = &.{},

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Build the project",
        .options = .{
            .release = .{ .short = 'r', .help = "Optimize for speed" },
            .jobs = .{ .short = 'j', .env = "USAGE_JOBS", .help = "Parallel jobs; 0 is one per core" },
            .target = .{ .value_name = "TRIPLE", .help = "The target to build for" },
            .files = .{ .positional = true, .hint = .file, .help = "Files to build" },
        },
    };
};

const Cli = struct {
    verbose: u8 = 0,
    color: enum { auto, always, never } = .auto,
    command: union(enum) {
        build: Build,
        completions: struct {
            shell: ensign.Shell,
            pub const spec: ensign.Spec(@This()) = .{
                .about = "Print a shell completion script",
                .options = .{ .shell = .{ .positional = true } },
            };
        },
    },

    pub const spec: ensign.Spec(@This()) = .{
        .name = "usage",
        .version = "1.0.0",
        .about = "Show what a declaration generates",
        .options = .{
            .verbose = .{ .short = 'v', .count = true, .global = true, .help = "Say more; repeat for more still" },
            .color = .{ .global = true, .env = "USAGE_COLOR", .help = "When to colour the output" },
        },
        .commands = .{ .build = .{ .aliases = &.{"b"} } },
        .examples = &.{.{ .command = "usage build -rj8 src/main.zig", .help = "Build one file for speed, eight jobs at a time." }},
    };
};
// --- README:declare ---

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    // --- README:main ---
    // Help, the version and mistakes are answered here, and the program exits.
    const cli = ensign.parseOrExit(Cli, init);
    switch (cli.command) {
        .build => |b| try out.print("verbose={d} color={t} jobs={d} target={s} files={d}\n", .{
            cli.verbose, cli.color, b.jobs, b.target orelse "native", b.files.len,
        }),
        .completions => |c| try ensign.writeCompletion(Cli, c.shell, out, "usage"),
    }
    // --- README:main ---
    try out.flush();
    try handled(init.gpa);
}

/// The same parse with the program in charge of mistakes.
fn handled(gpa: std.mem.Allocator) !void {
    // --- README:handled ---
    var diagnostic: ensign.Diagnostic = .{};
    const args: []const []const u8 = &.{ "build", "--relase" };
    if (ensign.parse(Cli, gpa, args, .{ .diagnostic = &diagnostic })) |_| {
        return error.ParsedAMistake;
    } else |err| {
        std.debug.assert(err == error.UnknownOption);
        var line: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&line);
        try diagnostic.writeMessage(&w);
        std.debug.assert(std.mem.eql(u8, w.buffered(), "usage build: unknown option '--relase'; did you mean '--release'?"));
    }
    // --- README:handled ---
}
