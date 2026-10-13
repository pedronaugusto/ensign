# ensign

ensign parses command lines in Zig. A program declares its arguments as a
struct, and the parser, the help pages and the shell completions are generated
from that declaration at compile time, with no registration at run time.

Work in progress toward the public cut.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/ensign`, then obtain the `ensign` module
through `b.dependency` and add it to your executable's imports. ensign depends
on Zig's standard library alone.

## Usage

A command is a struct. Its fields are its options and positionals, and at most
one tagged union holds its subcommands, each a struct of its own. The optional
`spec` declaration spells each field on the command line and gives the help:

<!-- BEGIN GENERATED zig build docs -- declare -->
```zig
const ensign = @import("ensign");

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
```
<!-- END GENERATED -->

`parseOrExit` reads the process's arguments and environment. `--help`,
`--version` and mistakes are answered there, and the program exits:

<!-- BEGIN GENERATED zig build docs -- main -->
```zig
const ensign = @import("ensign");

// Help, the version and mistakes are answered here, and the program exits.
const cli = ensign.parseOrExit(Cli, init);
switch (cli.command) {
    .build => |b| try out.print("verbose={d} color={t} jobs={d} target={s} files={d}\n", .{
        cli.verbose, cli.color, b.jobs, b.target orelse "native", b.files.len,
    }),
    .completions => |c| try ensign.writeCompletion(Cli, c.shell, out, "usage"),
}
```
<!-- END GENERATED -->

`usage build --relase` prints:

```
usage build: unknown option '--relase'; did you mean '--release'?
Usage: usage build [options] [FILES]...
Try 'usage build --help' for more information.
```

and exits with status 2. A program that handles mistakes itself calls `parse`
on any slice of arguments, and a `Diagnostic` says what went wrong:

<!-- BEGIN GENERATED zig build docs -- handled -->
```zig
const ensign = @import("ensign");

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
```
<!-- END GENERATED -->

## Design

Each field's type says how it is read:

| Field | On the command line |
|---|---|
| `bool` | `--name`, and `--no-name` unless `negatable = false`; `--name=false` also works |
| `?bool` | as `bool`, and null when neither is given |
| an integer | a value with an optional sign, `0x`, `0o` or `0b` prefix and `_` between digits; with `count = true`, how often the option is given (`-vvv`), saturating |
| a float | a value in Zig's float syntax, `inf` and `nan` included |
| an enum | a tag, written with `-` or `_` |
| `[]const u8` | the argument's bytes, borrowed; `hint = .file`, `.directory` or `.command` tells completions what it names |
| `?T` | null unless given |
| `[]const T` | every occurrence, in order; `delimiter` also splits one argument into several values |
| a tagged union, or an optional one | its subcommands, each a struct or `void` |

A field with a default may be left out; one without a default that is not
optional is required, by the command line or the environment. A `[]const u8`
is text, so a list of bytes is declared with a wider integer.

Values are spelled `--name=value`, `--name value`, `-n value`, `-nvalue` or
`-n=value`. Short flags cluster (`-abc`), and a short option that takes a value
ends its cluster with it (`-abo out.txt`, `-aboout.txt`). A value is taken as
it is, dashes included: `--output --` sets the output to `--`. A later value
replaces an earlier one, and a list adds to its own. `--` ends options; `-` is a
positional. Where no short option is a digit, `-5` is a positional too. Long
names are matched whole, never by a prefix.

Positionals are taken in declaration order; a list positional takes the rest
and comes last, and a command with subcommands has none. A subcommand's own
options follow its name. An option with `global = true` is accepted below its
command too, and its value stays in the command that declares it.

An option with `env` reads that variable when the command line does not give
it: the command line wins over the environment, and the environment over the
default. An empty variable counts as unset. Options in a `conflicts` group may
not be given together on the command line, and a value from the environment is
dropped when the command line gives another of its group.

A declaration that cannot be parsed unambiguously does not compile: two
options with one name, a list positional before another, positionals beside
subcommands, a subcommand option that hides a global one above it, a boolean
without a default, a name a shell cannot hold, a type no argument spells. The
error names the field and what to change.

Each command is a type the compiler builds. Long names and subcommands are
looked up in tables built at compile time: a few names are compared in turn,
more by one hash and usually one comparison. Each option's code is its own
branch. The parse walks the
arguments once and allocates only the lists a value holds; text borrows from
the arguments. Unknown names are answered with the nearest known one by edit
distance (insertions, deletions, substitutions and swaps of neighbours), when at
most a third of it differs.

Help is generated from the same declaration: the usage line, the description,
commands, positionals and options by section with their defaults, variables and
possible values, the global options of the commands above, examples and closing
sections. It is wrapped to the width asked for; `parseOrExit` asks the terminal
(`COLUMNS`, then the terminal itself) and wraps at 100 columns at most.

Completion scripts hold the whole command tree. Each finds the subcommand the
line is in by skipping options and their values as the parser does, then offers
that command's options, subcommands, enum values, or files, directories or
programs where the declaration hints at them. The bash script runs on bash 3.2
and later.

Arguments are bytes. On Windows `std.process.Args` decodes the command line from
WTF-16 to WTF-8, as std does everywhere, and an unpaired surrogate reaches a
text value as its WTF-8 bytes. Messages write bytes that are not printable
UTF-8 as `\xNN`.

## API

| Call | Does |
|---|---|
| `Spec(T)` | The declaration type: `name`, `version`, `about`, `description`, `options`, `commands`, `conflicts`, `examples`, `sections`, and the `help` and `version_flag` flags, null to leave them to the program |
| `Option` | A field's `help`, `short`, `long`, `aliases`, `value_name`, `env`, `positional`, `count`, `global`, `hidden`, `negatable`, `delimiter`, `hint` and `section` |
| `Command` | A subcommand's `help`, `name`, `aliases` and `hidden` |
| `parseOrExit(T, init)` | Parses the process's arguments; answers help, the version and mistakes, and exits |
| `parseArgs(T, arena, args, options)` | Parses a `std.process.Args`; decoded arguments and lists live in `arena` |
| `parse(T, gpa, args, options)` | Parses a slice of arguments after the program's name; lists are allocated with `gpa` |
| `Options` | The program's `name` for messages, the `environ` map, and the `diagnostic` to fill |
| `Outcome(T)` | `.parsed`, or `.help` and `.version`, which `write` themselves |
| `Error` | `UnknownOption`, `UnknownCommand`, `UnexpectedArgument`, `MissingValue`, `UnexpectedValue`, `InvalidValue`, `MissingOption`, `MissingArgument`, `MissingCommand`, `Conflict`, `OutOfMemory` |
| `Diagnostic` | What went wrong: `writeMessage` writes one line, `write` adds the usage and where help is |
| `free(T, gpa, value)` | Releases the lists `parse` allocated |
| `writeHelp(T, writer, program, width)` | Writes the root command's help |
| `writeCompletion(T, shell, writer, program)` | Writes the bash, zsh, fish or PowerShell script |
| `render(T, arena, value)` | The arguments that parse back to `value`, to start a child process with |
| `terminalWidth(io, file, environ)` | The columns of the terminal a file writes to, or null |

## Scope

- No abbreviated long options: `--verb` is not `--verbose`, and is answered
  with a suggestion.
- No custom value types yet: a field is one of the types above.
- No options that require or imply one another; `conflicts` is the one
  relation between options.
- No reading of configuration files; the environment is the one fallback.
- Completion scripts are static: they hold the tree, and never call the program.

## Platforms

The tests run on Linux, macOS and Windows, and CI compiles ensign for x86_64 and
aarch64 Linux (glibc and musl), macOS and Windows (GNU and MSVC), FreeBSD and
NetBSD. Parsing from a slice, help and completion scripts need no operating
system, and `bay check-freestanding` builds them for wasm32-freestanding;
`parseOrExit`, `parseArgs` and `terminalWidth` read the process and its
terminal.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing is linked.
- [bay](https://github.com/pedronaugusto/bay) runs ensign's development. [preflight](https://github.com/pedronaugusto/preflight) (the source checks, the tests and CI) and [shakedown](https://github.com/pedronaugusto/shakedown) (properties, allocators and benchmarks) are dev dependencies through bay, which a project that depends on ensign never sees.

## Testing

`bay test` runs the suite, the usage example and the declaration checks. The
suite covers each spelling, value type, error and its message, nesting four
levels deep, globals, aliases, the environment's precedence and conflicts, the
help pages word for word, and the process's own arguments, built as each system
holds them: WTF-16 with an unpaired surrogate on Windows. shakedown properties
write generated values as command lines in every spelling the syntax allows,
clusters and attached values among them, and parse them back; feed arbitrary
bytes to the parser, which parses or refuses them with a message and leaks
nothing; check that a name one edit from an option is answered with a real
one; and wrap help at every width. Parsing a value without lists is held to no
allocation, a value's lists to exactly what it keeps, and every allocation
failure is survived without a leak. `bay check-declarations` compiles each
rejected declaration and checks the error it gives.

The completion scripts run in the real shells, against the same cases: bash
on Linux in CI, where its absence fails the run, and zsh, fish and PowerShell
wherever they are installed; a shell that is missing elsewhere is skipped. Each
runs with a scratch home and no profile or rc file.

`bay bench` times parsing in ReleaseFast: 32 options of a 256-option command,
eight subcommands deep, a thousand list values, an unknown option among 256,
and an ordinary command line and its help page. CI compiles the benchmarks and
times nothing.

## Licence

MIT. See [LICENSE](LICENSE).
