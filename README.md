# depgraph

An interactive website of the dependency graph of a Lean 4, Agda or Rocq (Coq) library: folders,
modules and declarations, what uses what, the most used declarations, search, and the source of a
declaration when you hover over it.

Examples: [Mathlib](https://jobpetrovcic.github.io/Mathlib-Visualization-Deployment/),
[Riemann hypothesis](https://jobpetrovcic.github.io/Riemann-Hypothesis-Visualization-Deployment/)
([source](https://github.com/leanprover-community/riemann-hypothesis)),
[Rocq standard library](https://jobpetrovcic.github.io/Rocq-Stdlib-Visualization-Deployment/).

## Usage

Build your library first. Each command writes a website (a folder); view it with
`python3 -m http.server -d DIR` and open http://localhost:8000. The first run downloads the
`depgraph` program for your platform.

**Lean.** Add to `lakefile.toml`:

```toml
[[require]]
name = "depgraph"
git = "https://github.com/JobPetrovcic/depgraph"
rev = "main"
subDir = "lean"
```

then `lake update depgraph && lake build && lake exe depgraph` (website in `.lake/depgraph`).
`lake exe depgraph Mathlib` shows the given modules instead of your project's. Options: `-o DIR`,
`-j N` threads, `--no-aux`, `--name`, `--source URL`, `--no-source`, `--export FILE`.

**Rocq** (9.x):

```
opam pin add rocq-depgraph "git+https://github.com/JobPetrovcic/depgraph#main" --subpath rocq
rocq-depgraph            # website in depgraph-site; -o DIR to change; --no-aux
```

It reads the `-R`/`-Q` flags of `_CoqProject`, or give them: `rocq-depgraph -Q theories MyLib`
(for dune, the `.vo` files are taken from `_build/default`).

**Agda** (2.8): `agda-depgraph` is Agda with a `--depgraph` backend. Install it with
`cd agda && cabal install` (needs GHC 8.8–9.12 and `libgmp-dev`; about 20 minutes), then, next to
your `.agda-lib`:

```
agda-depgraph --depgraph src/Everything.agda     # a file importing everything
depgraph _depgraph -o site
```

Large libraries need a large heap, e.g. `+RTS -A128M -H4G -RTS`.

**Other languages:** write the declarations in the [common format](FORMAT.md) and run
`depgraph FILE -o DIR`. The program is attached to every
[release](https://github.com/JobPetrovcic/depgraph/releases).

## The website

A static folder: put it on any web server (not `file://`). It loads only the parts of the graph you
open, so it works for very large libraries. The source shown on hover is fetched from GitHub at the
commit you ran on, so push that commit first.

To publish a Lean project on GitHub Pages, add `.github/workflows/depgraph.yml` and set
Settings → Pages → Source to "GitHub Actions":

```yaml
name: Dependency graph
on: { push: { branches: [main] } }
permissions: { contents: read, pages: write, id-token: write }
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: leanprover/lean-action@v1
      - run: lake exe depgraph -o _site
      - uses: actions/upload-pages-artifact@v3
        with: { path: _site }
  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment: { name: github-pages }
    steps:
      - uses: actions/deploy-pages@v4
```

## The graph

An edge A → B means that A uses B in its statement or its proof/body, as the checked terms have it
(so including what tactics and type classes put there). Only declarations of the shown modules are
nodes. Generated declarations (Lean `f._proof_1`, `f.eq_1`, `T.rec`; Rocq `T_ind`, `f_subproof`)
are kept; `--no-aux` leaves them out (Mathlib: 600k → 346k declarations), and what they use then
counts as used by the declarations that use them. Agda with-functions and lambdas are always merged
into the declaration they belong to. Declarations created by Rocq functor
applications have no source lines.

Mathlib (600k declarations) takes 11 s on 16 threads; 1.4M declarations take 55 s and about 5 GB.
