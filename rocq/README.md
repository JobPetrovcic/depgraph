# depgraph for Rocq (Coq)

A Rocq plugin with one command, `DepGraph`, which writes the declarations of the loaded libraries
and what they use in the [depgraph format](../FORMAT.md), and a script `rocq-depgraph` that runs it
on a whole library and builds the website.

## Install

Needs Rocq 9 (tested with 9.3) and opam:

```
opam pin add rocq-depgraph "git+https://github.com/JobPetrovcic/depgraph#main" --subpath rocq
```

## Run

Build your library first (with `make`, `dune build`, ...). Then, in its directory:

```
rocq-depgraph
python3 -m http.server -d depgraph-site      # and open http://localhost:8000
```

This shows every compiled module under the `-R`/`-Q` directories of `_CoqProject`. Without a
`_CoqProject`, give the flags yourself, e.g. for a dune project `rocq-depgraph -Q theories MyLib`
(the `.vo` files are then taken from `_build/default/theories`). `-o DIR` sets the output directory.
The first run downloads the `depgraph` program for your platform (or set `DEPGRAPH_BIN`).

Or by hand, in a `.v` file that loads the library:

```
Declare ML Module "rocq-depgraph.plugin".
Require MyLib.All.
DepGraph "graph.jsonl" "MyLib".
```

then `depgraph graph.jsonl -o site`. The strings after the file name are the libraries to show:
each stands for itself and the modules below it.

## What is shown

Constants (definitions, theorems, axioms), inductive types and their constructors. What a
declaration uses is read from its type and body as the kernel has them, opaque proofs included, so
it also contains what tactics, notations and type classes put there.

The first line of a declaration is that of its name in the `.glob` file; the last is the end of
its sentence, or of its proof (`Qed`, `Defined`, `Admitted`, ...). Declarations made by functor
applications and `Include` have no line.
