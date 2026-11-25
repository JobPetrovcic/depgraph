# The depgraph format

What an extractor (for Lean, Agda, ...) writes and `depgraph` reads: JSON Lines (UTF-8), one
object per line, of three kinds.

```json
{"depgraph": 1, "library": "Mathlib"}
{"module": "Mathlib.Logic.Basic", "file": "/home/me/mathlib4/Mathlib/Logic/Basic.lean"}
{"decl": "not_not", "module": "Mathlib.Logic.Basic", "kind": "theorem", "line": 120, "end": 121, "uses": ["Not", "Classical.not_not"]}
```

- **Header** (optional, first line): the format version (`1`) and the name of the library.
  `"source"`: a base URL of the files (e.g. `https://github.com/OWNER/REPO/blob/COMMIT/`), when
  the `file`s are relative to it.
- **Module**: its name, with `.` separating the folders (`Mathlib.Logic.Basic` is the module
  `Basic` in the folder `Mathlib/Logic`), and optionally its source `file`: a local path (then
  `depgraph` finds the GitHub repository and commit of the file with `git`) or a path relative to
  the header's `source`. A module only named by declarations needs no line.
- **Declaration**: its name, which must be unique (later ones of the same name are dropped); its
  module; `kind`, e.g. `theorem`, `function`, `data`, `record`, `constructor`, `axiom` (any word);
  optionally the lines `line`..`end` of its source in the module's file; and the names it uses.
  Names of no declaration of the input (e.g. of other libraries) are ignored, so an extractor
  may write all of them or only those of the library.

Order does not matter, except that the declarations of a module are shown in input order.
