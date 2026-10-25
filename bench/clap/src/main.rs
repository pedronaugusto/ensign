//! ensign's bench/parse.zig rows through clap 4.6.7, clap_complete 4.6.11 and
//! clap_mangen 0.3.3: the same declarations and command lines. Each row is
//! timed in batches; 31 samples, the median printed in nanoseconds a unit, as
//! shakedown prints ensign's. `cargo run --release [-- ROW-PREFIX]`.
//!
//! With `COMPLETE=bash` in the environment this program is clap's
//! `CompleteEnv` program for the `git checkout --branch` completion, which the
//! process-level comparison times against ensign's `parseOrExit`.
use clap::builder::PossibleValuesParser;
use clap::{Arg, ArgAction, ArgGroup, Command};
use clap_complete::engine::{ArgValueCompleter, CompletionCandidate};
use std::ffi::{OsStr, OsString};
use std::hint::black_box;
use std::time::Instant;

fn wide() -> Command {
    let mut cmd = Command::new("wide");
    for i in 0..256usize {
        let name: &'static str = Box::leak(format!("option-{i}").into_boxed_str());
        let arg = Arg::new(name).long(name);
        cmd = cmd.arg(match i % 5 {
            0 => arg.value_parser(clap::value_parser!(u32)).default_value("0"),
            1 => arg.action(ArgAction::SetTrue),
            2 => arg.value_parser(PossibleValuesParser::new(["low", "middle", "high"])).default_value("low"),
            3 => arg.default_value(""),
            _ => arg.action(ArgAction::Append),
        });
    }
    cmd
}

fn deep(depth: usize) -> Command {
    let cmd = Command::new(if depth == 8 { "deep" } else { "next" })
        .arg(Arg::new("flag").long("flag").action(ArgAction::SetTrue))
        .arg(Arg::new("value").long("value").value_parser(clap::value_parser!(u32)).default_value("0"))
        .arg(Arg::new("name").long("name").default_value(""));
    if depth == 0 { cmd } else { cmd.subcommand(deep(depth - 1)) }
}

fn small() -> Command {
    Command::new("small")
        .about("A program's ordinary command line")
        .arg(Arg::new("verbose").short('v').long("verbose").action(ArgAction::Count).global(true).help("Say more"))
        .subcommand_required(true)
        .subcommand(
            Command::new("build")
                .arg(Arg::new("release").short('r').long("release").action(ArgAction::SetTrue).help("Optimize for speed"))
                .arg(Arg::new("jobs").short('j').long("jobs").value_parser(clap::value_parser!(u16)).default_value("0").help("Parallel jobs"))
                .arg(Arg::new("target").long("target"))
                .arg(Arg::new("files").action(ArgAction::Append).value_hint(clap::ValueHint::FilePath)),
        )
}

#[derive(Clone, Copy)]
struct Address {
    octets: [u8; 4],
    port: u16,
}

fn address(s: &str) -> Result<Address, String> {
    let (host, port) = s.rsplit_once(':').ok_or("an address such as 10.0.0.1:8080")?;
    let mut octets = [0u8; 4];
    let mut parts = host.split('.');
    for o in &mut octets {
        *o = parts.next().and_then(|p| p.parse().ok()).ok_or("an address such as 10.0.0.1:8080")?;
    }
    if parts.next().is_some() {
        return Err("an address such as 10.0.0.1:8080".into());
    }
    Ok(Address { octets, port: port.parse().map_err(|_| "a port")? })
}

fn custom(typed: bool) -> Command {
    let listen = Arg::new("listen").long("listen");
    let peers = Arg::new("peers").long("peers").value_delimiter(',').action(ArgAction::Append);
    if typed {
        Command::new("custom").arg(listen.value_parser(address)).arg(peers.value_parser(address))
    } else {
        Command::new("custom").arg(listen).arg(peers)
    }
}

fn related(declared: bool) -> Command {
    let mut cmd = Command::new("related")
        .arg(Arg::new("key").long("key"))
        .arg(Arg::new("cert").long("cert"))
        .arg(Arg::new("ca").long("ca"))
        .arg(Arg::new("token").long("token"))
        .arg(Arg::new("password").long("password"))
        .arg(Arg::new("ci").long("ci").action(ArgAction::SetTrue))
        .arg(Arg::new("color").long("color").value_parser(PossibleValuesParser::new(["auto", "always", "never"])).default_value("auto"))
        .arg(Arg::new("progress").long("progress").action(ArgAction::SetTrue));
    if declared {
        cmd = cmd
            .mut_arg("key", |a| a.requires_ifs([(clap::builder::ArgPredicate::IsPresent, "cert"), (clap::builder::ArgPredicate::IsPresent, "ca")]))
            .group(ArgGroup::new("auth").args(["token", "password"]).required(true).multiple(true))
            .mut_arg("color", |a| a.default_value_if("ci", clap::builder::ArgPredicate::IsPresent, Some("never")));
    }
    cmd
}

fn branches(current: &OsStr) -> Vec<CompletionCandidate> {
    let prefix = current.to_string_lossy();
    ["main", "maint", "master", "next", "release-1.0", "release-1.1", "topic/one", "topic/two"]
        .iter()
        .filter(|b| b.starts_with(&*prefix))
        .map(|b| CompletionCandidate::new(*b))
        .collect()
}

fn checkout() -> Command {
    Command::new("git")
        .arg(Arg::new("verbose").short('v').long("verbose").action(ArgAction::Count))
        .subcommand(
            Command::new("checkout")
                .arg(Arg::new("force").long("force").action(ArgAction::SetTrue))
                .arg(Arg::new("branch").short('b').long("branch").add(ArgValueCompleter::new(branches))),
        )
}

fn strings(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

/// Times `f`, `units` at a time, as shakedown does: a batch grown until it
/// takes a millisecond, then 31 samples; prints the median per unit.
fn row(name: &str, unit: &str, filter: &str, mut f: impl FnMut()) {
    if !name.starts_with(filter) {
        return;
    }
    let mut batch = 1u64;
    loop {
        let t = Instant::now();
        for _ in 0..batch {
            f();
        }
        if t.elapsed().as_nanos() > 1_000_000 || batch > 1 << 24 {
            break;
        }
        batch *= 2;
    }
    let mut samples: Vec<f64> = (0..31)
        .map(|_| {
            let t = Instant::now();
            for _ in 0..batch {
                f();
            }
            t.elapsed().as_nanos() as f64 / batch as f64
        })
        .collect();
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("{{\"row\":\"{name}\",\"unit\":\"{unit}\",\"best\":{:.1},\"median\":{:.1},\"rival\":\"clap 4.6.7\"}}", samples[0], samples[15]);
}

fn main() {
    if std::env::var_os("COMPLETE").is_some() {
        clap_complete::CompleteEnv::with_factory(checkout).complete();
        return;
    }
    let filter = std::env::args().nth(1).unwrap_or_default();

    let mut wide_args = vec!["wide".to_string()];
    for n in 0..32usize {
        let i = n * 8 + n % 5;
        wide_args.push(match i % 5 {
            0 => format!("--option-{i}={n}"),
            1 => format!("--option-{i}"),
            2 => format!("--option-{i}=high"),
            3 => format!("--option-{i}=text"),
            _ => format!("--option-{i}=item"),
        });
    }
    let mut deep_args = vec!["deep".to_string()];
    for _ in 0..8 {
        deep_args.extend(strings(&["--flag", "--value=7", "next"]));
    }
    deep_args.extend(strings(&["--name", "leaf"]));
    let mut list_args = vec!["wide".to_string()];
    list_args.extend(std::iter::repeat("--option-4=item".to_string()).take(1000));
    let ordinary = strings(&["small", "-vv", "build", "-rj8", "--target=x86_64-linux", "a.zig", "b.zig", "c.zig"]);
    let addresses = strings(&["custom", "--listen=10.0.0.1:8080", "--peers=10.0.0.2:9000,10.0.0.3:9000,10.0.0.4:9000"]);
    let related_args = strings(&["related", "--key=k.pem", "--cert=c.pem", "--ca=ca.pem", "--token=t", "--ci"]);

    // clap builds a command once and parses with it many times, as a program
    // does once; ensign's tables are built at compile time.
    let mut w = wide();
    w.build();
    row("wide/32 of 256 options", "parse", &filter, || {
        black_box(w.clone().try_get_matches_from(&wide_args).unwrap());
    });
    let mut d = deep(8);
    d.build();
    row("deep/8 subcommands", "parse", &filter, || {
        black_box(d.clone().try_get_matches_from(&deep_args).unwrap());
    });
    row("lists/1000 values", "parse", &filter, || {
        black_box(w.clone().try_get_matches_from(&list_args).unwrap());
    });
    row("errors/unknown among 256", "parse", &filter, || {
        black_box(w.clone().try_get_matches_from(["wide", "--option-12x"]).unwrap_err().to_string());
    });
    let mut s = small();
    s.build();
    row("small/command line", "parse", &filter, || {
        black_box(s.clone().try_get_matches_from(&ordinary).unwrap());
    });
    row("small/help page", "page", &filter, || {
        black_box(s.render_help().to_string());
    });
    let mut typed = custom(true);
    typed.build();
    row("custom/address type", "parse", &filter, || {
        let m = typed.clone().try_get_matches_from(&addresses).unwrap();
        black_box(m.get_one::<Address>("listen").map(|a| (a.octets, a.port)));
    });
    let mut untyped = custom(false);
    untyped.build();
    row("custom/same text unread", "parse", &filter, || {
        black_box(untyped.clone().try_get_matches_from(&addresses).unwrap());
    });
    let mut declared = related(true);
    declared.build();
    row("relations/declared", "parse", &filter, || {
        black_box(declared.clone().try_get_matches_from(&related_args).unwrap());
    });
    let mut none = related(false);
    none.build();
    row("relations/none", "parse", &filter, || {
        black_box(none.clone().try_get_matches_from(&related_args).unwrap());
    });
    let mut git = checkout();
    git.build();
    let words: Vec<OsString> = ["git", "-v", "checkout", "--force", "--branch", "ma"].iter().map(OsString::from).collect();
    row("complete/answer", "answer", &filter, || {
        black_box(clap_complete::engine::complete(&mut git, words.clone(), 5, None).unwrap());
    });
    let build = s.find_subcommand("build").unwrap().clone();
    row("man/subcommand page", "page", &filter, || {
        let mut out = Vec::new();
        clap_mangen::Man::new(build.clone()).date("2026-10-25").render(&mut out).unwrap();
        black_box(out);
    });
}
