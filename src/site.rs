//! Writing the website. The page loads the graph lazily, in chunks:
//!
//!     graph_data.js              var graphManifest = {...}
//!     graph_data/n_<k>.json      {name:[], label:[], parent:[], nchild:[], in_degree:[], ...}
//!     graph_data/a_<k>.bin       out-neighbours of the chunk's nodes
//!     graph_data/r_<k>.bin       in-neighbours
//!     graph_data/names_<j>.json  all names, for the search
//!
//! Chunk `k` holds the nodes `k * CHUNK ... (k+1) * CHUNK - 1`. Neighbour chunks (little endian):
//! uint32 rows; uint32 byteOffset[rows + 1]; then every row's neighbours, sorted, delta coded and
//! LEB128 encoded.

use crate::graph::Graph;
use crate::source::Files;
use rayon::prelude::*;
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::Path;

const CHUNK: usize = 1024;
const NAMES_PER_FILE: usize = 100_000;
const TOP: usize = 500;

const WEB: &[(&str, &str)] = &[
    ("index.html", include_str!("../web/index.html")),
    ("visualize.html", include_str!("../web/visualize.html")),
    ("scripts/helpers.js", include_str!("../web/scripts/helpers.js")),
    ("scripts/constants.js", include_str!("../web/scripts/constants.js")),
    ("scripts/librarySpecificSettings.js", include_str!("../web/scripts/librarySpecificSettings.js")),
    ("scripts/setUpData.js", include_str!("../web/scripts/setUpData.js")),
    ("scripts/setupSvg.js", include_str!("../web/scripts/setupSvg.js")),
    ("scripts/sourceCard.js", include_str!("../web/scripts/sourceCard.js")),
    ("scripts/moduleConnections.js", include_str!("../web/scripts/moduleConnections.js")),
    ("scripts/expansion.js", include_str!("../web/scripts/expansion.js")),
    ("scripts/arrangeTree.js", include_str!("../web/scripts/arrangeTree.js")),
];

fn json(s: &str) -> String {
    serde_json::to_string(s).unwrap()
}

fn array(xs: impl Iterator<Item = String>) -> String {
    format!("[{}]", xs.collect::<Vec<_>>().join(","))
}

/// Four significant digits, e.g. `1234e-9`.
fn float4(x: f64) -> String {
    if x == 0.0 {
        return "0".to_string();
    }
    let e = x.abs().log10().floor() - 3.0;
    let m = (x / 10f64.powf(e)).round();
    format!("{}e{}", m as i64, e as i64)
}

fn varint(b: &mut Vec<u8>, mut v: u32) {
    while v >= 128 {
        b.push((v % 128 + 128) as u8);
        v /= 128;
    }
    b.push(v as u8);
}

fn encode_rows(rows: &[Vec<u32>]) -> Vec<u8> {
    let mut data = Vec::new();
    let mut offsets = Vec::with_capacity(rows.len() + 1);
    for r in rows {
        offsets.push(data.len() as u32);
        let mut prev = 0;
        for &v in r {
            varint(&mut data, v - prev);
            prev = v;
        }
    }
    offsets.push(data.len() as u32);
    let mut b = Vec::with_capacity(4 * (offsets.len() + 1) + data.len());
    b.extend((rows.len() as u32).to_le_bytes());
    for o in offsets {
        b.extend(o.to_le_bytes());
    }
    b.extend(data);
    b
}

pub fn write(g: &Graph, files: &Files, out: &Path) -> io::Result<()> {
    let n = g.names.len();
    let dir = out.join("graph_data");
    fs::create_dir_all(&dir)?;
    for e in fs::read_dir(&dir)? {
        let p = e?.path();
        if p.extension().is_some_and(|x| x == "json" || x == "bin") {
            fs::remove_file(p)?;
        }
    }
    let mut labels: Vec<&String> = g.labels.iter().collect();
    labels.sort();
    labels.dedup();
    let label_idx: HashMap<&String, usize> = labels.iter().enumerate().map(|(i, l)| (*l, i)).collect();
    let mut in_adj = vec![Vec::new(); n];
    for (u, o) in g.out.iter().enumerate() {
        for &v in o {
            in_adj[v as usize].push(u as u32);
        }
    }
    let chunks = n.div_ceil(CHUNK);
    (0..chunks).into_par_iter().try_for_each(|k| -> io::Result<()> {
        let (lo, hi) = (k * CHUNK, n.min((k + 1) * CHUNK));
        let col = |f: &dyn Fn(usize) -> String| array((lo..hi).map(f));
        let mut table = vec![
            format!("\"name\":{}", col(&|u| json(&g.names[u]))),
            format!("\"label\":{}", col(&|u| label_idx[&g.labels[u]].to_string())),
            format!("\"parent\":{}", col(&|u| g.parent[u].to_string())),
            format!("\"nchild\":{}", col(&|u| g.out[u].len().to_string())),
            format!("\"in_degree\":{}", col(&|u| g.in_degree[u].to_string())),
            format!("\"out_degree\":{}", col(&|u| g.out_degree[u].to_string())),
            format!("\"pagerank\":{}", col(&|u| float4(g.pagerank[u]))),
            format!(
                "\"range\":{}",
                col(&|u| g.range[u].map_or("null".to_string(), |(a, b)| format!("[{a},{b}]")))
            ),
        ];
        // the source file of each module (only in the chunks of folders and modules)
        if lo < g.tree_count {
            let file = |u: usize| files.file.get(u).cloned().flatten().map_or("null".to_string(), |f| json(&f));
            table.push(format!("\"file\":{}", col(&file)));
        }
        fs::write(dir.join(format!("n_{k}.json")), format!("{{{}}}", table.join(",")))?;
        fs::write(dir.join(format!("a_{k}.bin")), encode_rows(&g.out[lo..hi]))?;
        fs::write(dir.join(format!("r_{k}.bin")), encode_rows(&in_adj[lo..hi]))
    })?;
    let names_files = n.div_ceil(NAMES_PER_FILE);
    for j in 0..names_files {
        let names = &g.names[j * NAMES_PER_FILE..n.min((j + 1) * NAMES_PER_FILE)];
        fs::write(dir.join(format!("names_{j}.json")), array(names.iter().map(|s| json(s))))?;
    }
    let mut top: Vec<usize> = (0..n).collect();
    top.sort_by_key(|&u| (std::cmp::Reverse(g.in_degree[u]), u));
    top.truncate(TOP);
    let edges: usize = g.out.iter().map(|o| o.len()).sum();
    let mut manifest = vec![
        "\"version\":3".to_string(),
        "\"format\":\"bin1\"".to_string(),
        "\"generator\":\"depgraph\"".to_string(),
        format!("\"chunkSize\":{CHUNK}"),
        format!("\"namesFiles\":{names_files}"),
        format!("\"nodeCount\":{n}"),
        format!("\"edgeCount\":{edges}"),
        format!("\"labels\":{}", array(labels.iter().map(|l| json(l)))),
        "\"stats\":[\"in_degree\",\"out_degree\",\"pagerank\"]".to_string(),
        "\"root\":0".to_string(),
        format!("\"roots\":[{{\"id\":0,\"name\":{}}}]", json(&g.names[0])),
        format!(
            "\"topIndegree\":{}",
            array(top.iter().map(|&u| format!("[{u},{},{}]", json(&g.names[u]), g.in_degree[u])))
        ),
    ];
    if let Some(b) = &files.base {
        manifest.push(format!("\"source\":{}", json(b)));
    }
    fs::write(out.join("graph_data.js"), format!("var graphManifest = {{{}}};\n", manifest.join(",")))?;
    for (path, text) in WEB {
        let f = out.join(path);
        if let Some(p) = f.parent() {
            fs::create_dir_all(p)?;
        }
        fs::write(f, text)?;
    }
    Ok(())
}
