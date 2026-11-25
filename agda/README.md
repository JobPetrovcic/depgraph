# depgraph for Agda

`agda-depgraph` is Agda 2.8 with one extra backend, `--depgraph`, which writes the declarations of
the checked modules and what they use in the [depgraph format](../FORMAT.md).

## Install

Needs a GHC that Agda 2.8 supports (8.8 – 9.12; tested with GHC 9.10.1 and cabal 3.16) and the
GMP library (`libgmp-dev` on Debian/Ubuntu). Building Agda takes a while (about 20 minutes with many cores).

```
cd agda
cabal install
```

This puts `agda-depgraph` in `~/.local/bin` (or `~/.cabal/bin`). It is a full Agda 2.8:
use it in place of `agda`.

## Run

In the directory of your library (the one with the `.agda-lib` file), on a file that imports
everything:

```
agda-depgraph --depgraph src/Everything.agda
depgraph _depgraph -o site
python3 -m http.server -d site      # and open http://localhost:8000
```

`--depgraph-dir DIR` writes to `DIR` instead of `_depgraph`: one `<module>.jsonl` per module and
`_header.jsonl` with the library name (the `name:` of the `.agda-lib`, else the directory name).
Old `.jsonl` files in it are removed first. Already checked modules are not checked again, but
are still written.

Large libraries need a large heap: e.g. for agda-unimath, add `+RTS -A128M -H4G -RTS`.

The source lines of a declaration (shown on hover) are guessed from the layout: from the line of
its name to the next declaration, keyword (`module`, `open`, `field`, ...) or comment at the same or
lower indentation, a less indented line, or the end of the code block. With-functions and
(extended or absurd) lambdas are not shown; what they use counts as used by the declaration they
belong to.
Local definitions whose names print the same (`where` blocks of different clauses, like
`M._.eqn`) get their line added: `M._.eqn@42`.
