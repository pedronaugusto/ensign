# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Pins aegis 0.2.1, the 0.2 line: `SecretBytes` holds no allocator.
- Pins xenoglyph 0.5.1.

## [0.3.0] - 2026-10-25

### Breaking

- `Outcome` has a fourth variant, `.complete`, a completion script's request, which `parseArgs` returns when `ENSIGN_COMPLETE` is set; an exhaustive switch names it. `Problem` has two more, `required_by` and `missing_one`.

### Added

- A type reads itself: an `ensign_value` declaration (contract 1) names the type's own `parse`, what a value must be, and the words for each error `parse` returns; `format` writes it back for help and `render`. Any struct, enum or tagged union, from any package, with nothing imported. A declaration of another shape, a later contract, a missing `format`, words for an error `parse` never returns or `aegis_scalar` beside it does not compile.
- Relations between options: `requires` (an option needs others), `required_groups` (at least one of a group) and `implies` (values an option sets, below the command line and the environment), checked after the environment, shown in help and on the usage line, and written by `render`.
- Dynamic completion: `Option.complete`, or `ensign_value.complete` on a type, names a completer the program runs; the bash, zsh, fish and PowerShell scripts ask the program with `ENSIGN_COMPLETE=1:<key>` and the words typed, and `parseOrExit` answers. `Completion`, `Completer`, `CompletionRequest` and `completionRequest` for programs that answer themselves.
- Manual pages: `writeManPage` writes roff with the man(7) macros for any command of the declaration, clean under mandoc's lint; `commands` lists every command's path.

### Fixed

- An aegis integer, Duration or Bytes from a program pinning another aegis version than ensign's was refused, a `Ranged` as "a non-exhaustive enum, whose values have no names to read" (bay's `--jobs` under a plain `zig build`): ensign recognized aegis's scalars by rebuilding them with its own copy of aegis, and two versions are two copies whose types are never equal. It now reads the `aegis_scalar` declaration each one carries (aegis 0.1.18), the same in every copy, at contract 1: its bounds and unit come from it, a value is made only through the type's own checked functions, and a later contract does not compile, named by its number.

## [0.2.4] - 2026-10-24

### Changed

- Pins xenoglyph 0.4.2 and aegis 0.1.17.

## [0.2.3] - 2026-10-14

### Changed

- Pins xenoglyph 0.4.0, aegis 0.1.7: the family on one xenoglyph line.

## [0.2.2] - 2026-10-14

### Changed

- Pins aegis 0.1.6, xenoglyph 0.3.1.

## [0.2.1] - 2026-10-13

### Added

- `Option.raw`: a positional list of text that takes every argument from the first the command does not read as one of its options, as given, for programs that pass arguments on to another.
- `ensign.External`: a subcommand that takes any name no other has, with the arguments after it as given, for commands found at run time.

## [0.2.0] - 2026-10-13

### Breaking

- A non-exhaustive enum is refused at compile time, naming the field and what to use instead. It compiled before and then refused every value a command line gave it, since its values beyond the tags have no names.

### Added

- aegis's checked scalars are option and positional values. `int.Ranged`, `Checked` and `Saturating`, `units.Count`, `id.Id` and `NonZero` are read as integers their type checks, so `--jobs` declared `Ranged(u16, 1, 256)` takes 1 to 256; `units.Duration` is read in aegis's duration text (`30s`, `1m30s`, `250ms`) and `units.Bytes` in its size text (`4096`, `64MiB`, `1.5GB`), exact to the type. Each is recognized by the parameters aegis publishes, never by its name. Help shows their defaults and `render` writes them back in the same text; completions take them as free text.
- A mistake in one of them names what was expected: `an integer from 1 to 256`, `a duration such as 30s or 1m30s`, `a duration in whole milliseconds` for a finer one, or the range a duration or size must be in.

### Fixed

- Help wraps where a line may break by Unicode's rules (UAX #14), through xenoglyph: Chinese and Japanese text breaks between its characters, and never before a closing mark such as `。`. It broke only at spaces, so a CJK description never wrapped. ASCII text still breaks only at spaces, so an option, a path or a hyphenated word stays whole, and glued words never break.

### Changed

- Depends on aegis 0.1.4, for its checked scalars and their text, and pins xenoglyph 0.2.0.
- The gate holds glint's aegis rules A001 to A004.

## [0.1.1] - 2026-10-13

### Fixed

- Help measures text in the columns a terminal gives it, through xenoglyph: a CJK description takes two columns a character, a combining mark none, so wide text wraps and aligns where it is drawn. It counted one column a code point.

## [0.1.0] - 2026-10-13

### Added

- `Spec(T)`: a command's arguments declared as a struct, its subcommands as a tagged union, and their spelling and help beside them; the parser is generated at compile time.
- Integers, floats, enums, text, paths, flags with `--no-` negation, counts, optionals and lists with an optional delimiter; defaults, required options and positionals.
- `--name=value`, `--name value`, `-n value`, `-nvalue`, `-n=value`, short clusters, `--` and `-`.
- Subcommands nested to any depth, with aliases, and options that stay visible below their command.
- Environment fallbacks: the command line, then the environment, then the default; conflict groups.
- Help generated from the declaration, wrapped to the terminal, with sections and examples; `--help` and `--version` the program can turn off or rename.
- Completion scripts for bash, zsh, fish and PowerShell.
- `Diagnostic`: messages for unknown options and commands with the nearest name by edit distance, missing and bad values naming the type expected, and conflicts.
- `parse` on a slice, `parseArgs` on `std.process.Args`, `parseOrExit` for a program's `main`; `render` writes a value back as arguments; `terminalWidth`.

[Unreleased]: https://github.com/pedronaugusto/ensign/commits/main
