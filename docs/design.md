# Architecture

ensign turns a struct a program declares into a parser, help pages, completion scripts and manual pages, all built at
compile time. The README says what a declaration means on the command line; this page says how the code is laid out
and why the choices are what they are. Change it with the code.

Runtime closure: ensign → xenoglyph (terminal columns) and aegis (checked scalars and their text) → std. Parsing a
slice, help and completion scripts need no operating system; `process.zig` alone reads the process and its terminal.

## Modules

| File | Holds |
|---|---|
| `spec.zig` | The declaration a program writes: `Spec(T)`, `Option`, `Command`, the relations' types |
| `model.zig` | The declaration read at compile time: each command's options, positionals and subcommands, each option's `Kind` (`flag`, `count`, `single`, `list`); every declaration error is a compile error here |
| `kinds.zig` | What a value's type is: `integer`, `float`, `boolean`, `enumeration`, `text`, `checked`, `duration`, `size`, `custom`, `none` |
| `value.zig` | One value from its text (`read`), back to text (`write`), and the words for what was expected (`expected`) |
| `lookup.zig` | Names to numbers: a table built at compile time, a few names compared in turn, more by one hash and usually one comparison |
| `parse.zig` | The command line read once against the model, one frame per command |
| `diagnostic.zig` | What went wrong, in words, with the nearest known name |
| `help.zig`, `text.zig` | Usage lines and help pages (`Pages(chain, names)`, one comptime page per command), wrapped by Unicode line breaking, never inside an ASCII word |
| `complete.zig`, `complete/tree.zig` | Scripts for bash, zsh, fish and PowerShell from one tree of nodes keyed `path:spelling` and `path:#n` |
| `completer.zig` | Completions the program answers itself (`ENSIGN_COMPLETE`) |
| `man.zig` | roff with the man(7) macros |
| `render.zig` | A value written back as the arguments that parse to it |
| `process.zig` | `parseOrExit`, `parseArgs`, `terminalWidth` |

## One path per value

A value's type decides how it is read, through one path: `kinds.of(V)` names its `Kind`, and `value.read`,
`value.write` and `value.expected` act on it. The parser, help's `[default: ...]`, `render`, completion's kind and
the man page all go through that path, so a type is read and written the same way everywhere.

aegis values are recognised by the `aegis_scalar` literal their type publishes (contract 1), never by name. A type
of any package reads itself the same way with an `ensign_value` literal, nothing imported:

- `.contract = 1`, `.expected` (completes "expected ..."), `.parse` (`fn ([]const u8) E!T` or `?T`), optionally
  `.refused` (words for each error of `E`, checked against `E` at compile time) and `.complete`. `format` is
  required, since help and `render` write every value. Both literals on one type, a later contract or words for an
  error `parse` never returns do not compile. Zig errors carry no payload, so every message is known at compile time.
- The value may borrow the argument, as text does; parsing without lists allocates nothing, and the suite holds it so.

## The parse

One walk over the arguments, each option's code its own comptime branch. `Frame.finish` settles a command in this
order, each step reading what the last settled: lists, `conflicts`, the environment, `implies` (to a fixed point, so
an implied option implies in turn), `requires`, `required_groups`, required options, positionals. Given means the
command line or the environment; the command line wins over the environment, the environment over an implied value,
and that over the default (an implied value is a conditional default). A missing need is `MissingOption` with the
problem `required_by` or `missing_one`, so `Error` keeps its set.

## Completion

Scripts are static and hold the whole tree: each finds the command the line is in by skipping options and their
values as the parser does, then offers spellings, subcommands, enum values, or files, directories and programs where
a `hint` says so. Options, subcommands and enum values never start the program.

Where only the program knows the values, a field's `complete` (or its type's `ensign_value.complete`; the field's
wins) answers. The script runs the command as typed with `ENSIGN_COMPLETE=1:<key>`, the words before the cursor and
then the word being completed; the program prints one candidate a line, a tab before its description. The key is
already known to the script, so the program does not walk the line again. `1` is the protocol's version: a script and
a program of different protocols refuse each other. `parseArgs` returns the request as `Outcome.complete`, the same
shape as `.help` and `.version`. A completer that cannot answer calls `fail`; the message goes to standard error,
which scripts discard and a person running the line by hand reads.

## Manual pages

`writeManPage(T, writer, options)` writes one command's page (NAME, SYNOPSIS, DESCRIPTION, commands, arguments and
options by help's sections, global options, ENVIRONMENT, EXAMPLES, the declaration's sections, VERSION, SEE ALSO);
`commands(T)` lists every command's path, so the program writes `prog.1`, `prog-build.1`. ensign writes text and never
files. Escaping: `\` as `\e`, a leading `.` or `'` guarded by `\&`, `-` in names as `\-` (groff would make it a
hyphen) but bare inside `.TH` arguments so mandoc reads the date; lines stay under 80 bytes. The check is mandoc:
pages word for word and clean under `mandoc -T lint -W all`.

## Rules

- A declaration that cannot be parsed unambiguously does not compile, and the error names the field.
- No abbreviated long options, no configuration files, no files written.
- Arguments are bytes; on Windows std decodes the command line to WTF-8, and messages show bytes that are not
  printable UTF-8 as `\xNN`.

## The bar

Measured against clap 4.6 on the same command lines: parsing at or below clap's time; a custom type costs its own
`parse`; relations cost nothing when none are declared; a dynamic completion answer within 2x of clap's
`CompleteEnv`, process start included; manual pages at least as fast as clap_mangen. Timings are taken on a quiet
machine; CI compiles the benchmarks and times nothing.
