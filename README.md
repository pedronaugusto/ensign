# ensign

ensign parses command lines in Zig. A program declares its arguments as a
struct, and the parser, the help pages and the shell completions are generated
from that declaration at compile time, with no registration at run time.

Work in progress toward the public cut.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/ensign`, then obtain the `ensign` module
through `b.dependency` and add it to your executable's imports. ensign depends
on [xenoglyph](https://github.com/pedronaugusto/xenoglyph), for the columns
text takes in a terminal, and [aegis](https://github.com/pedronaugusto/aegis),
whose checked scalars are values a command line gives.

## Usage

A command is a struct. Its fields are its options and positionals, and at most
one tagged union holds its subcommands, each a struct of its own. The optional
`spec` declaration spells each field on the command line and gives the help:

<!-- BEGIN GENERATED zig build docs -- declare -->
```zig
const ensign = @import("ensign");
const aegis = @import("aegis");

const Build = struct {
    release: bool = false,
    jobs: ?aegis.int.Ranged(u16, 1, 256) = null,
    timeout: aegis.units.Duration(.millisecond, u64) = .fromRaw(30_000),
    max_size: aegis.units.Bytes(u64) = .fromRaw(64 << 20),
    target: ?[]const u8 = null,
    files: []const []const u8 = &.{},

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Build the project",
        .options = .{
            .release = .{ .short = 'r', .help = "Optimize for speed" },
            .jobs = .{ .short = 'j', .env = "USAGE_JOBS", .help = "Parallel jobs; one per core when not given" },
            .timeout = .{ .help = "Give up on a step after this long, as 30s or 1m30s" },
            .max_size = .{ .help = "The largest output, as 4096, 64MiB or 1.5GB" },
            .target = .{ .value_name = "TRIPLE", .complete = targets, .help = "The target to build for" },
            .files = .{ .positional = true, .hint = .file, .help = "Files to build" },
        },
    };
};

// --- README:completer ---
/// The program answers what `--target` completes to: the shell asks it.
fn targets(c: *ensign.Completion) ensign.Completion.Error!void {
    const known = [_][2][]const u8{ .{ "aarch64-macos", "Apple silicon" }, .{ "x86_64-linux", "Linux on x86-64" }, .{ "x86_64-windows", "Windows on x86-64" } };
    for (known) |t| if (std.mem.startsWith(u8, t[0], c.prefix)) try c.add(t[0], t[1]);
}
// --- README:completer ---

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
        man: struct {
            command: []const []const u8 = &.{},
            pub const spec: ensign.Spec(@This()) = .{
                .about = "Print the manual page of a command",
                .options = .{ .command = .{ .positional = true } },
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
    .build => |b| try out.print("verbose={d} color={t} jobs={d} timeout={f} target={s} files={d}\n", .{
        cli.verbose, cli.color, if (b.jobs) |jobs| jobs.raw() else 0, b.timeout, b.target orelse "native", b.files.len,
    }),
    .completions => |c| try ensign.writeCompletion(Cli, c.shell, out, "usage"),
    .man => |m| try manual(out, m.command),
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
| aegis's `int.Ranged`, `Checked` and `Saturating`, `units.Count`, `id.Id` and `NonZero` | an integer, as above, that the type checks: `Ranged(u16, 1, 256)` takes 1 to 256, `NonZero` refuses 0 |
| aegis's `units.Duration` | aegis's duration text, exact to the type's unit: `30s`, `1m30s`, `250ms`, `1.5h` |
| aegis's `units.Bytes` | aegis's size text, binary and decimal units spelled apart: `4096`, `64MiB`, `1.5GB` |
| `?T` | null unless given |
| `[]const T` | every occurrence, in order; `delimiter` also splits one argument into several values |
| a tagged union, or an optional one | its subcommands, each a struct or `void` |
| `ensign.External`, as one subcommand's type | any name no other subcommand has, with every argument after it as given: commands found at run time, as git's and cargo's |
| a type declaring `ensign_value` | read by the type's own `parse`, and written back by its `format`: an address, a duration of your own, a struct, enum or tagged union |

An aegis value is recognized by the parameters its type publishes, never by
its name, and help shows its default as the command line spells it
(`[default: 30s]`, `[default: 64MiB]`). A mistake names what was expected: `an
integer from 1 to 256`, `a duration such as 30s or 1m30s`, `a duration in
whole milliseconds` for `1.5ms`, or the range a duration or size must be in.
Other non-exhaustive enums are refused at compile time, as are aegis's
`Instant`, `Bits` and `Counter`, which have no command-line text.

A type reads itself by declaring what it is, as aegis's scalars do, with
nothing imported, so a library's type serves ensign without depending on it:

```zig
pub const Address = struct {
    octets: [4]u8,
    port: u16,

    pub const ensign_value = .{
        .contract = 1,
        .expected = "an address such as 10.0.0.1:8080",
        .parse = parse, // fn ([]const u8) E!Address, or ?Address
        .refused = .{ .PortRange = "a port from 1 to 65535" },
    };
    pub fn parse(bytes: []const u8) error{ Malformed, PortRange }!Address { ... }
    pub fn format(a: Address, w: *std.Io.Writer) std.Io.Writer.Error!void { ... }
};
```

`.expected` completes "expected ..." in a mistake's message, and `.refused`
names the words for each error `parse` returns. A value may borrow the
argument, as text does, and nothing is allocated for it. Help shows its default
and `render` writes it with `format`. A tagged union that declares
`ensign_value` is one value, not subcommands. A declaration of another shape,
a later contract, a missing `format`, words for an error `parse` never returns
or `aegis_scalar` beside it does not compile.

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
and comes last, and a command with subcommands has none. With `raw = true`, a
list of text takes every argument from the first the command does not read as
one of its options, dashes and `--` included, as a program that wraps another
passes them on (`bay build -Doptimize=ReleaseSafe`); a `--` before them is
dropped. A subcommand's own
options follow its name. An option with `global = true` is accepted below its
command too, and its value stays in the command that declares it.

An option with `env` reads that variable when the command line does not give
it: the command line wins over the environment, and the environment over the
default. An empty variable counts as unset. Options in a `conflicts` group may
not be given together on the command line, and a value from the environment is
dropped when the command line gives another of its group.

Three more relations are declared beside `conflicts`. `requires` says an
option needs others: with `.requires = &.{.{ .option = .key, .needs =
&.{.cert} }}`, `--key` without `--cert` is refused with `'--key' needs '--cert
<CERT>'`. A `required_groups` entry needs at least one of its options (and,
also in `conflicts`, exactly one). `implies` sets values when an option is
given: `.{ .option = .ci, .sets = .{ .color = .never, .progress = false } }`.
Given means the command line or the environment, and an implied option implies
in turn. The command line wins over the environment, the environment over an
implied value, and that over the default. Help shows `[requires: --cert]` and
`[implies: --color=never, --no-progress]` beside the option, and a required
group on the usage line as `<--token|--password>`; `render` writes what a
relation needs even at its default.

A declaration that cannot be parsed unambiguously does not compile: two
options with one name, a list positional before another, positionals beside
subcommands, a subcommand option that hides a global one above it, a boolean
without a default, a name a shell cannot hold, a type no argument spells, a
non-exhaustive enum. The
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
sections. It is wrapped to the width asked for, where Unicode's line breaking
rules let a line break (between Chinese or Japanese characters too), though
never inside an ASCII word, so an option or a path stays whole; `parseOrExit`
asks the terminal (`COLUMNS`, then the terminal itself) and wraps at 100
columns at most.

Completion scripts hold the whole command tree. Each finds the subcommand the
line is in by skipping options and their values as the parser does, then offers
that command's options, subcommands, enum values, or files, directories or
programs where the declaration hints at them; an aegis value is free text. The bash script runs on bash 3.2
and later.

Where only the program knows the values (branches, hosts, targets), a field
names a completer, `.complete = targets`, or its type declares one in
`ensign_value.complete`:

<!-- BEGIN GENERATED zig build docs -- completer -->
```zig
const ensign = @import("ensign");

/// The program answers what `--target` completes to: the shell asks it.
fn targets(c: *ensign.Completion) ensign.Completion.Error!void {
    const known = [_][2][]const u8{ .{ "aarch64-macos", "Apple silicon" }, .{ "x86_64-linux", "Linux on x86-64" }, .{ "x86_64-windows", "Windows on x86-64" } };
    for (known) |t| if (std.mem.startsWith(u8, t[0], c.prefix)) try c.add(t[0], t[1]);
}
```
<!-- END GENERATED -->

The script then runs the command as typed with `ENSIGN_COMPLETE=1:<key>` and
the words before the cursor, then the word being completed, as its arguments;
`parseOrExit` answers with one candidate a line, a tab before its description,
and exits (`parseArgs` returns the request as `.complete`). Options,
subcommands and enum values never start the program. A completer that cannot
answer says why with `fail`: the program exits 1 with the message on standard
error, which the scripts discard and a person running the line by hand reads.
The `1` is the protocol's version, so a script and a program of different
protocols refuse each other.

`writeManPage` writes a command's manual page in roff with the man(7) macros,
which mandoc and groff both read: NAME, SYNOPSIS, DESCRIPTION, its commands,
arguments and options by help's sections, the global options above it,
ENVIRONMENT for every variable an option reads, EXAMPLES, the declaration's own
sections, VERSION and SEE ALSO. `commands(T)` lists every command's path, so a
program writes them all as `prog.1`, `prog-build.1`:

<!-- BEGIN GENERATED zig build docs -- man -->
```zig
const ensign = @import("ensign");

/// The page of the command `path` names (`usage man build`), for `man -l -`.
fn manual(out: *std.Io.Writer, path: []const []const u8) !void {
    try ensign.writeManPage(Cli, out, .{ .date = "2026-10-25", .manual = "User Commands", .command = path });
}
```
<!-- END GENERATED -->

Arguments are bytes. On Windows `std.process.Args` decodes the command line from
WTF-16 to WTF-8, as std does everywhere, and an unpaired surrogate reaches a
text value as its WTF-8 bytes. Messages write bytes that are not printable
UTF-8 as `\xNN`.

## API

| Call | Does |
|---|---|
| `Spec(T)` | The declaration type: `name`, `version`, `about`, `description`, `options`, `commands`, `conflicts`, `requires`, `required_groups`, `implies`, `examples`, `sections`, and the `help` and `version_flag` flags, null to leave them to the program |
| `Option` | A field's `help`, `short`, `long`, `aliases`, `value_name`, `env`, `positional`, `count`, `global`, `hidden`, `negatable`, `delimiter`, `hint`, `complete`, `section` and `raw` |
| `Command` | A subcommand's `help`, `name`, `aliases` and `hidden` |
| `External` | The payload of a subcommand that takes any other name: the `name` given and its `args` |
| `parseOrExit(T, init)` | Parses the process's arguments; answers help, the version and mistakes, and exits |
| `parseArgs(T, arena, args, options)` | Parses a `std.process.Args`; decoded arguments and lists live in `arena` |
| `parse(T, gpa, args, options)` | Parses a slice of arguments after the program's name; lists are allocated with `gpa` |
| `Options` | The program's `name` for messages, the `environ` map, and the `diagnostic` to fill |
| `Outcome(T)` | `.parsed`, or `.help` and `.version`, which `write` themselves, or `.complete`, a completion script's request |
| `Error` | `UnknownOption`, `UnknownCommand`, `UnexpectedArgument`, `MissingValue`, `UnexpectedValue`, `InvalidValue`, `MissingOption` (a required option, one a given option requires, or none of a required group), `MissingArgument`, `MissingCommand`, `Conflict`, `OutOfMemory` |
| `Diagnostic` | What went wrong: `writeMessage` writes one line, `write` adds the usage and where help is |
| `free(T, gpa, value)` | Releases the lists `parse` allocated |
| `writeHelp(T, writer, program, width)` | Writes the root command's help |
| `writeCompletion(T, shell, writer, program)` | Writes the bash, zsh, fish or PowerShell script |
| `Completion`, `Completer` | What a completer is given (`prefix`, `args`, `io`, `gpa`, `environ`) and offers with `add(value, description)`, or refuses with `fail(message)` |
| `CompletionRequest`, `completionRequest(T, asked, words)` | A script's request and its `answer`; `parseArgs` makes it from `ENSIGN_COMPLETE` |
| `writeManPage(T, writer, options)` | Writes the manual page of the command at `options.command`, with its `section`, `date`, `source` and `manual` |
| `commands(T)` | Every command's path of subcommand names, the root first |
| `render(T, arena, value)` | The arguments that parse back to `value`, to start a child process with |
| `terminalWidth(io, file, environ)` | The columns of the terminal a file writes to, or null |

## Scope

- No abbreviated long options: `--verb` is not `--verbose`, and is answered
  with a suggestion.
- No reading of configuration files; the environment is the one fallback.
- No files written: `writeManPage` and `writeCompletion` write text, and the
  program decides where it goes.

## Platforms

The tests run on Linux, macOS and Windows, and CI compiles ensign for x86_64 and
aarch64 Linux (glibc and musl), macOS and Windows (GNU and MSVC), FreeBSD and
NetBSD. Parsing from a slice, help and completion scripts need no operating
system, and `bay check-freestanding` builds them for wasm32-freestanding;
`parseOrExit`, `parseArgs` and `terminalWidth` read the process and its
terminal.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing is linked.
- [xenoglyph](https://github.com/pedronaugusto/xenoglyph) measures help in terminal columns, and [aegis](https://github.com/pedronaugusto/aegis) gives the checked integers, durations and sizes and their text.
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
nothing; write aegis values back and parse them to themselves, and take every
value of a range and the sizes at either end of a representation, refusing
one past them; check that a name one edit from an option is answered with a real
one; and wrap help at every width. Parsing a value without lists is held to no
allocation, a value's lists to exactly what it keeps, and every allocation
failure is survived without a leak. Types that read themselves are read in
every spelling, round trip through `render`, and take arbitrary bytes or
refuse them with their own words, allocating nothing. Arbitrary command lines
against a declaration with every relation parse to values that hold each
relation or are refused with a message, and `render` writes what the
relations need. Any completion request is answered or refused with a reason.
Manual pages are checked word for word, rendered by mandoc and held clean under
its lint at every level (`-W all`), where mandoc is installed. `bay
check-declarations` compiles each rejected declaration and checks the error it
gives.

The completion scripts run in the real shells, against the same cases: bash
on Linux in CI, where its absence fails the run, and zsh, fish and PowerShell
wherever they are installed; a shell that is missing elsewhere is skipped. Each
runs with a scratch home and no profile or rc file. The scripts that ask the
program run against a stand-in on the search path, which answers with the key
and the words it was given.

`bay bench` times parsing in ReleaseFast: 32 options of a 256-option command,
eight subcommands deep, a thousand list values, an unknown option among 256,
and an ordinary command line and its help page. CI compiles the benchmarks and
times nothing.

## Licence

MIT. See [LICENSE](LICENSE).
