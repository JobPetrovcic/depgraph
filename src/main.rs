//! depgraph: writes the website of a library's dependency graph, read in the depgraph format
//! (FORMAT.md), as written by the extractors for Lean and Agda.

mod graph;
mod site;
mod source;

use rayon::prelude::*;
use serde::Deserialize;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Instant;

const USAGE: &str = "usage: depgraph [options] [INPUT...]

Writes the website of a library's dependency graph. INPUT: files in the depgraph format
(FORMAT.md), or directories of such files (*.jsonl); none or `-`: standard input.

  -o, --out DIR    output directory (default: depgraph-site)
  -j, --jobs N     threads (default: all cores)
  --name NAME      name of the library (default: from the input, or the first module)
  --source URL     base URL of the source files on GitHub, e.g.
                   https://github.com/OWNER/REPO/blob/COMMIT/ (default: found with git)
  --no-source      do not link the source
  --no-aux         leave out auxiliary declarations (marked \"aux\"); what they use counts
                   as used by the declarations that use them";

/// One line of the input.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Line {
    pub depgraph: Option<u32>,
    pub library: Option<String>,
    pub source: Option<String>,
    pub module: Option<String>,
    pub file: Option<String>,
    pub decl: Option<String>,
    pub kind: Option<String>,
    pub line: Option<u32>,
    pub end: Option<u32>,
    pub uses: Option<Vec<String>>,
    pub aux: Option<bool>,
}

fn jsonl_below(dir: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for e in std::fs::read_dir(dir)? {
        let p = e?.path();
        if p.is_dir() {
            jsonl_below(&p, out)?;
        } else if p.extension().is_some_and(|x| x == "jsonl") {
            out.push(p);
        }
    }
    Ok(())
}

fn fail(msg: impl std::fmt::Display) -> ! {
    eprintln!("depgraph: {msg}");
    std::process::exit(1)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut inputs = Vec::new();
    let mut out = PathBuf::from("depgraph-site");
    let mut jobs = 0;
    let mut name = None;
    let mut source_arg = None;
    let mut no_source = false;
    let mut no_aux = false;
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].clone();
        let mut value = || {
            i += 1;
            args.get(i).cloned().unwrap_or_else(|| fail(format!("{arg} needs a value\n\n{USAGE}")))
        };
        match arg.as_str() {
            "-h" | "--help" => {
                println!("{USAGE}");
                return;
            }
            "-V" | "--version" => {
                println!("depgraph {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            "-o" | "--out" => out = PathBuf::from(value()),
            "-j" | "--jobs" => jobs = value().parse().unwrap_or_else(|_| fail("-j: not a number")),
            "--name" => name = Some(value()),
            "--source" => source_arg = Some(value()),
            "--no-source" => no_source = true,
            "--no-aux" => no_aux = true,
            a if a.starts_with('-') && a != "-" => fail(format!("unknown option {a}\n\n{USAGE}")),
            a => inputs.push(a.to_string()),
        }
        i += 1;
    }
    rayon::ThreadPoolBuilder::new().num_threads(jobs).build_global().unwrap();
    let t0 = Instant::now();
    let log = |s: String| eprintln!("[{:.1}s] {s}", t0.elapsed().as_secs_f64());

    // read
    let mut files = Vec::new();
    for a in &inputs {
        let p = PathBuf::from(a);
        if a != "-" && p.is_dir() {
            let mut below = Vec::new();
            jsonl_below(&p, &mut below).unwrap_or_else(|e| fail(format!("{a}: {e}")));
            below.sort();
            files.extend(below.into_iter().map(Some));
        } else {
            files.push(if a == "-" { None } else { Some(p) });
        }
    }
    if files.is_empty() {
        files.push(None);
    }
    let texts: Vec<(String, String)> = files
        .iter()
        .map(|f| match f {
            None => {
                let mut s = String::new();
                std::io::stdin().read_to_string(&mut s).unwrap_or_else(|e| fail(format!("standard input: {e}")));
                ("standard input".to_string(), s)
            }
            Some(p) => (
                p.display().to_string(),
                std::fs::read_to_string(p).unwrap_or_else(|e| fail(format!("{}: {e}", p.display()))),
            ),
        })
        .collect();
    let lines: Vec<(usize, usize, &str)> = texts
        .iter()
        .enumerate()
        .flat_map(|(f, (_, t))| t.strip_prefix('\u{feff}').unwrap_or(t).lines().enumerate().map(move |(k, l)| (f, k, l)))
        .filter(|(_, _, l)| !l.trim().is_empty())
        .collect();
    let parsed: Vec<Line> = lines
        .par_iter()
        .map(|&(f, k, l)| {
            serde_json::from_str(l).unwrap_or_else(|e| fail(format!("{}:{}: {e}", texts[f].0, k + 1)))
        })
        .collect();
    drop(lines);
    drop(texts);
    log(format!("read {} lines", parsed.len()));

    let mut input = graph::Input::from_lines(parsed).unwrap_or_else(|e| fail(e));
    input.dedup();
    if no_aux {
        let n = input.drop_aux();
        log(format!("left out {n} auxiliary declarations"));
    }
    let lib_name = name
        .or(input.library.clone())
        .or_else(|| input.modules.keys().min().map(|m| m.split('.').next().unwrap().to_string()))
        .unwrap_or_else(|| "library".to_string());
    let g = graph::build(&input, &lib_name, &log);
    let files = if no_source {
        source::Files::none(g.tree_count)
    } else {
        let base = source_arg.or(input.source.clone());
        source::resolve(&g, &input, base)
    };
    log(format!("writing the website to {}", out.display()));
    site::write(&g, &files, &out).unwrap_or_else(|e| fail(format!("{}: {e}", out.display())));
    log(format!("done: {} nodes, {} edges", g.names.len(), g.out.iter().map(|o| o.len()).sum::<usize>()));
}
