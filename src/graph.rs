//! The graph. Nodes: the library (id 0), then folders and modules, numbered breadth-first, then
//! the declarations, grouped by module in module order. An edge `A → B` means "A uses B".
//! Folders and modules have edges to what they contain and to the modules their declarations use.

use crate::Line;
use rayon::prelude::*;
use std::collections::HashMap;

pub struct Decl {
    pub name: String,
    pub module: String,
    pub kind: String,
    pub range: Option<(u32, u32)>,
    pub uses: Vec<String>,
}

pub struct Input {
    pub library: Option<String>,
    pub source: Option<String>,
    /// module -> its source file, if given
    pub modules: HashMap<String, Option<String>>,
    pub decls: Vec<Decl>,
}

impl Input {
    pub fn from_lines(lines: Vec<Line>) -> Result<Input, String> {
        let mut input = Input { library: None, source: None, modules: HashMap::new(), decls: Vec::new() };
        for l in lines {
            if let Some(v) = l.depgraph {
                if v != 1 {
                    return Err(format!("input in format version {v}; this depgraph reads version 1 (update it)"));
                }
                input.library = l.library.or(input.library);
                input.source = l.source.or(input.source);
            } else if let Some(name) = l.decl {
                let module = l.module.ok_or_else(|| format!("declaration {name} without a module"))?;
                input.modules.entry(module.clone()).or_insert(None);
                let range = l.line.map(|a| (a, l.end.unwrap_or(a).max(a)));
                let kind = l.kind.unwrap_or_else(|| "declaration".to_string());
                input.decls.push(Decl { name, module, kind, range, uses: l.uses });
            } else if let Some(m) = l.module {
                let f = input.modules.entry(m).or_insert(None);
                if l.file.is_some() {
                    *f = l.file;
                }
            } else {
                return Err("a line that is no header, module or declaration".to_string());
            }
        }
        Ok(input)
    }
}

pub struct Graph {
    /// number of library/folder/module nodes; they have the ids `0 .. tree_count`
    pub tree_count: usize,
    pub names: Vec<String>,
    pub labels: Vec<String>,
    /// the containing node, -1 for the library
    pub parent: Vec<i64>,
    pub range: Vec<Option<(u32, u32)>>,
    /// out-neighbours, sorted
    pub out: Vec<Vec<u32>>,
    pub in_degree: Vec<u32>,
    pub out_degree: Vec<u32>,
    pub pagerank: Vec<f64>,
    /// module nodes: their module name
    pub module_of_node: HashMap<usize, String>,
}

/// The components of a module name, split at `.` (not inside `«»`), as (end in `s`, name).
fn components(s: &str) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    let mut quoted = false;
    let mut start = 0;
    for (i, c) in s.char_indices() {
        match c {
            '«' => quoted = true,
            '»' => quoted = false,
            '.' if !quoted => {
                out.push((i, s[start..i].replace(['«', '»'], "")));
                start = i + 1;
            }
            _ => {}
        }
    }
    out.push((s.len(), s[start..].replace(['«', '»'], "")));
    out
}

fn sort_dedup(mut a: Vec<u32>) -> Vec<u32> {
    a.sort_unstable();
    a.dedup();
    a
}

/// PageRank (damping 0.85, dangling mass spread uniformly) of the graph with `n` nodes, given by
/// the out-degrees and the in-neighbours.
fn pagerank(n: usize, out_deg: &[u32], in_adj: &[Vec<u32>]) -> Vec<f64> {
    let d = 0.85;
    let mut pr = vec![1.0 / n as f64; n];
    for _ in 0..200 {
        let share: Vec<f64> =
            (0..n).into_par_iter().map(|u| if out_deg[u] > 0 { pr[u] / out_deg[u] as f64 } else { 0.0 }).collect();
        let dangling: f64 = (0..n).into_par_iter().filter(|&u| out_deg[u] == 0).map(|u| pr[u]).sum();
        let base = (1.0 - d) / n as f64 + d * dangling / n as f64;
        let next: Vec<f64> = (0..n)
            .into_par_iter()
            .map(|v| base + d * in_adj[v].iter().map(|&u| share[u as usize]).sum::<f64>())
            .collect();
        let diff: f64 = next.par_iter().zip(&pr).map(|(a, b)| (a - b).abs()).sum();
        pr = next;
        if diff < 1e-10 {
            break;
        }
    }
    pr
}

pub fn build(input: &Input, lib_name: &str, log: &dyn Fn(String)) -> Graph {
    // folders and modules, in order of creation
    let mut modules: Vec<&String> = input.modules.keys().collect();
    modules.sort();
    let mut names = vec![format!("library_{lib_name}")];
    let mut labels = vec![":library".to_string()];
    let mut parent = vec![0usize];
    let mut index: HashMap<&str, usize> = HashMap::new();
    let mut module_node_old = Vec::with_capacity(modules.len());
    for m in &modules {
        let comps = components(m);
        let mut p = 0;
        for (k, (end, name)) in comps.iter().enumerate() {
            let label = if k + 1 == comps.len() { ":module" } else { ":namespace" };
            let key = &m[..*end];
            p = match index.get(key) {
                Some(&i) => {
                    if label == ":module" {
                        labels[i] = label.to_string();
                    }
                    i
                }
                None => {
                    let i = names.len();
                    names.push(name.clone());
                    labels.push(label.to_string());
                    parent.push(p);
                    index.insert(key, i);
                    i
                }
            };
        }
        module_node_old.push(p);
    }
    // breadth-first ids
    let t = names.len();
    let mut children = vec![Vec::new(); t];
    for v in 1..t {
        children[parent[v]].push(v);
    }
    let mut new_id = vec![0usize; t];
    let mut queue = vec![0usize];
    let mut head = 0;
    while head < queue.len() {
        let u = queue[head];
        new_id[u] = head;
        head += 1;
        queue.extend_from_slice(&children[u]);
    }
    let mut old_of = vec![0usize; t];
    for i in 0..t {
        old_of[new_id[i]] = i;
    }
    let module_node: HashMap<&str, usize> =
        modules.iter().zip(&module_node_old).map(|(m, &o)| (m.as_str(), new_id[o])).collect();

    // declarations, grouped by module in node order (the first declaration of a name wins)
    let mut by_module: HashMap<&str, Vec<usize>> = HashMap::new();
    for (i, d) in input.decls.iter().enumerate() {
        by_module.entry(d.module.as_str()).or_default().push(i);
    }
    let mut order: Vec<&str> = modules.iter().map(|m| m.as_str()).collect();
    order.sort_by_key(|m| module_node[m]);
    let mut decls: Vec<(&Decl, usize)> = Vec::with_capacity(input.decls.len()); // decl, module node
    let mut decl_id: HashMap<&str, u32> = HashMap::with_capacity(input.decls.len());
    let mut first_decl = vec![(0usize, 0usize); t]; // module node -> declarations' range
    for m in &order {
        let start = decls.len();
        for &i in by_module.get(m).map(|v| v.as_slice()).unwrap_or(&[]) {
            let d = &input.decls[i];
            if decl_id.contains_key(d.name.as_str()) {
                continue;
            }
            decl_id.insert(&d.name, decls.len() as u32);
            decls.push((d, module_node[m]));
        }
        first_decl[module_node[m]] = (start, decls.len());
    }
    let n_decls = decls.len();
    log(format!("{t} folders and modules, {n_decls} declarations"));

    // dependencies
    let deps: Vec<Vec<u32>> = decls
        .par_iter()
        .enumerate()
        .map(|(i, (d, _))| {
            sort_dedup(d.uses.iter().filter_map(|u| decl_id.get(u.as_str()).copied()).filter(|&j| j != i as u32).collect())
        })
        .collect();
    log(format!("{} dependencies between declarations", deps.iter().map(|d| d.len()).sum::<usize>()));

    // statistics of the declaration graph
    let out_deg: Vec<u32> = deps.iter().map(|d| d.len() as u32).collect();
    let mut in_adj = vec![Vec::new(); n_decls];
    for (u, ds) in deps.iter().enumerate() {
        for &v in ds {
            in_adj[v as usize].push(u as u32);
        }
    }
    let pr = pagerank(n_decls, &out_deg, &in_adj);

    // the whole graph
    let mut module_deps = vec![Vec::new(); t];
    for (u, ds) in deps.iter().enumerate() {
        let m = decls[u].1;
        for &v in ds {
            let m2 = decls[v as usize].1;
            if m2 != m {
                module_deps[m].push(m2 as u32);
            }
        }
    }
    let mut child_ids = vec![Vec::new(); t];
    for v in 1..t {
        child_ids[new_id[parent[old_of[v]]]].push(v as u32);
    }
    let tc = t as u32;
    let mut out: Vec<Vec<u32>> = Vec::with_capacity(t + n_decls);
    for u in 0..t {
        let (a, b) = first_decl[u];
        let mut o = std::mem::take(&mut child_ids[u]);
        o.extend((a as u32..b as u32).map(|v| v + tc));
        o.extend(std::mem::take(&mut module_deps[u]));
        out.push(sort_dedup(o));
    }
    for ds in &deps {
        out.push(ds.iter().map(|v| v + tc).collect());
    }
    let mut in_degree = vec![0u32; t + n_decls];
    for o in &out {
        for &v in o {
            in_degree[v as usize] += 1;
        }
    }
    let module_of_node = module_node.iter().map(|(m, &v)| (v, m.to_string())).collect();
    Graph {
        tree_count: t,
        names: (0..t).map(|v| names[old_of[v]].clone()).chain(decls.iter().map(|(d, _)| d.name.clone())).collect(),
        labels: (0..t)
            .map(|v| labels[old_of[v]].clone())
            .chain(decls.iter().map(|(d, _)| format!(":{}", d.kind)))
            .collect(),
        parent: (0..t)
            .map(|v| if v == 0 { -1 } else { new_id[parent[old_of[v]]] as i64 })
            .chain(decls.iter().map(|&(_, m)| m as i64))
            .collect(),
        range: std::iter::repeat_n(None, t).chain(decls.iter().map(|(d, _)| d.range)).collect(),
        // declarations: degrees in the declaration graph; folders and modules: in the whole graph
        in_degree: in_degree[..t].iter().copied().chain(in_adj.iter().map(|a| a.len() as u32)).collect(),
        out_degree: out[..t].iter().map(|o| o.len() as u32).chain(out_deg).collect(),
        pagerank: std::iter::repeat_n(0.0, t).chain(pr).collect(),
        out,
        module_of_node,
    }
}
