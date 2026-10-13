# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
