# The clap rival

ensign's `bench/parse.zig` rows through clap 4.6.7, clap_complete 4.6.11 and
clap_mangen 0.3.3, on the same declarations and command lines. Run by hand,
never by CI:

```
bay dev bench                                   # ensign's rows, ReleaseFast
cargo run --release --manifest-path bench/clap/Cargo.toml
python3 -I bench/clap/process.py zig-out/bench/complete bench/clap/target/release/ensign-bench-clap
```

The last times a completion answered from process start: ensign's
`bench/complete` (`ENSIGN_COMPLETE`) against this crate's `CompleteEnv`
(`COMPLETE=bash`), the same tree and completer, alternating runs.
