//! Where the page finds the source of a module: a GitHub URL, found with git from the local file.

use crate::graph::{Graph, Input};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Files {
    /// base URL of the files (`https://github.com/OWNER/REPO/blob/COMMIT/`)
    pub base: Option<String>,
    /// per folder/module node: its file, relative to `base`, or a full URL
    pub file: Vec<Option<String>>,
}

impl Files {
    pub fn none(tree_count: usize) -> Files {
        Files { base: None, file: vec![None; tree_count] }
    }
}

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let o = Command::new("git").arg("-C").arg(dir).args(args).output().ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// `https://github.com/OWNER/REPO/blob/COMMIT/` of the git checkout at `root`, if it is from GitHub.
fn blob_url(root: &Path) -> Option<String> {
    let commit = git(root, &["rev-parse", "HEAD"])?;
    let url = git(root, &["remote", "get-url", "origin"])?;
    let url = url.strip_suffix(".git").unwrap_or(&url);
    let Some(repo) = ["https://github.com/", "git@github.com:", "ssh://git@github.com/"].iter().find_map(|p| url.strip_prefix(p)) else {
        eprintln!("note: {url} is not on GitHub, so the page shows no source of {}", root.display());
        return None;
    };
    if git(root, &["status", "--porcelain"]).is_some_and(|s| !s.is_empty()) {
        eprintln!(
            "note: the page shows the source of {} at commit {}, without your uncommitted changes",
            root.display(),
            &commit[..12.min(commit.len())]
        );
    }
    Some(format!("https://github.com/{repo}/blob/{commit}/"))
}

/// The root of the git checkout containing `dir`.
fn repo_root(dir: &Path, cache: &mut HashMap<PathBuf, Option<PathBuf>>) -> Option<PathBuf> {
    if let Some(r) = cache.get(dir) {
        return r.clone();
    }
    let r = if dir.join(".git").exists() { Some(dir.to_path_buf()) } else { dir.parent().and_then(|p| repo_root(p, cache)) };
    cache.insert(dir.to_path_buf(), r.clone());
    r
}

pub fn resolve(g: &Graph, input: &Input, base: Option<String>) -> Files {
    let mut files = Files::none(g.tree_count);
    let module_file = |v: usize| g.module_of_node.get(&v).and_then(|m| input.modules[m].clone());
    let cwd = std::env::current_dir().unwrap_or_default();
    let mut roots = HashMap::new();
    if let Some(mut base) = base {
        // files relative to the base: local files relative to their git checkout
        if !base.ends_with('/') {
            base.push('/');
        }
        for v in 0..g.tree_count {
            files.file[v] = module_file(v).map(|f| {
                let local = Path::new(&f);
                let in_repo = (local.is_absolute() || local.exists())
                    .then(|| cwd.join(local).canonicalize().ok())
                    .flatten()
                    .and_then(|p| {
                        let root = p.parent().and_then(|d| repo_root(d, &mut roots))?;
                        p.strip_prefix(&root).ok().map(url_path)
                    });
                in_repo.unwrap_or_else(|| url_path(local))
            });
        }
        files.base = Some(base);
        return files;
    }
    let mut located: Vec<(usize, PathBuf, PathBuf)> = Vec::new(); // node, repo root, file in it
    for v in 0..g.tree_count {
        let Some(f) = module_file(v) else { continue };
        let Ok(path) = cwd.join(f).canonicalize() else { continue };
        let Some(root) = path.parent().and_then(|d| repo_root(d, &mut roots)) else { continue };
        if let Ok(rel) = path.strip_prefix(&root) {
            located.push((v, root.clone(), rel.to_path_buf()));
        }
    }
    let mut count: HashMap<&PathBuf, usize> = HashMap::new();
    for (_, r, _) in &located {
        *count.entry(r).or_default() += 1;
    }
    let mut urls: HashMap<&PathBuf, Option<String>> = HashMap::new();
    for r in count.keys() {
        urls.insert(r, blob_url(r));
    }
    // the base is the repository of most modules; the others' files get their full URL
    let main = count.iter().filter(|(r, _)| urls[*r].is_some()).max_by_key(|(r, c)| (**c, std::cmp::Reverse(*r))).map(|(r, _)| *r);
    files.base = main.and_then(|r| urls[r].clone());
    for (v, r, rel) in &located {
        let rel = url_path(rel);
        files.file[*v] = match &urls[r] {
            Some(_) if Some(r) == main => Some(rel),
            Some(u) => Some(format!("{u}{rel}")),
            None => None,
        };
    }
    files
}

/// A relative path as a URL path: its components joined by `/`, percent-encoded.
fn url_path(p: &Path) -> String {
    p.components()
        .map(|c| {
            let mut s = String::new();
            for b in c.as_os_str().to_string_lossy().bytes() {
                if b.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@".contains(&b) {
                    s.push(b as char);
                } else {
                    s.push_str(&format!("%{b:02X}"));
                }
            }
            s
        })
        .collect::<Vec<_>>()
        .join("/")
}
