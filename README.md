# depgraph

Builds an interactive website of the dependency graph of a Lean 4 project: folders, modules and
declarations, what uses what, the most used declarations, search, and the source of a declaration
(statement, proof on request) when you hover over it.

## Usage

Add to your project's `lakefile.toml`:

```toml
[[require]]
name = "depgraph"
git = "https://github.com/JobPetrovcic/depgraph"
rev = "main"
```

(or `require depgraph from git "https://github.com/JobPetrovcic/depgraph" @ "main"` in a `lakefile.lean`), then

```
lake update depgraph
lake build
lake exe depgraph
python3 -m http.server -d .lake/depgraph      # and open http://localhost:8000
```

Without arguments it shows the modules your project has built; `lake exe depgraph Mathlib` shows
Mathlib instead (any module names: each stands for itself and the modules below it). Options:

```
  -o, --out DIR    output directory (default: .lake/depgraph)
  -j, --jobs N     threads (default: all cores)
  --name NAME      name of the library (default: the first module or the directory)
  --source URL     source of the modules on GitHub (default: found with git)
  --no-source      do not link the source
```

The output is a static website (a folder of files): put it on any web server. The page loads only
the parts of the graph you open, so it also works for very large libraries. It needs a web server,
not `file://`.

The source shown on hover is fetched from GitHub, at the commit you ran the tool on, so that commit
must be pushed.

## Publishing on GitHub Pages

`.github/workflows/depgraph.yml` (and under Settings → Pages, set the source to "GitHub Actions"):

```yaml
name: Dependency graph
on:
  push:
    branches: [main]
permissions:
  contents: read
  pages: write
  id-token: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: leanprover/lean-action@v1   # installs Lean, gets cached builds (`lake exe cache get`) if the project uses Mathlib, builds the rest
      - run: lake exe depgraph -o _site
      - uses: actions/upload-pages-artifact@v3
        with:
          path: _site
  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
    steps:
      - uses: actions/deploy-pages@v4
```

A free GitHub runner has about 14 GB of disk, enough for projects of Mathlib's size; a project
whose compiled files are larger needs a bigger runner or to run the tool locally.

## Scale

On 16 threads, Mathlib (600k declarations) takes 23 s and under 1 GB of memory; a project with
1.4M declarations takes 80 s and 2 GB (plus the compiled files, which are mapped from disk). The
website is about 200–230 bytes per declaration: 120 MB for Mathlib.

## The graph

An edge A → B means that A uses B: in its statement, its proof or body, or as an inductive type's
constructor. Only declarations of the shown modules are nodes. A declaration's degree counts its
edges to other shown declarations. Auxiliary declarations (`f._proof_1`, `f.eq_1`, ...) are kept,
and show the source of the declaration they belong to. Modules that declare `main` and are imported
by no other module (roots of executables, e.g. build scripts) are left out.
