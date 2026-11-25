import Lean
import DepGraph.Graph
import DepGraph.Site
open Lean System DepGraph

def usage : String := "usage: lake exe depgraph [options] [MODULE...]

Writes a website showing the dependency graph of a Lean library: by default of the
current project (the modules it has built, in .lake/build/lib/lean), otherwise of the
modules MODULE and MODULE.* (e.g. Mathlib). Build the modules first (`lake build`).

  -o, --out DIR    output directory (default: .lake/depgraph)
  -j, --jobs N     threads (default: all cores)
  --name NAME      name of the library (default: the first MODULE or the directory)
  --source URL     source of the modules on GitHub, e.g.
                   https://github.com/OWNER/REPO/blob/COMMIT/src/ (default: found with git)
  --no-source      do not link the source"

structure Config where
  modules : Array Name := #[]
  out : FilePath := ".lake" / "depgraph"
  jobs : Nat := 0
  name : Option String := none
  source : Option String := none
  noSource : Bool := false

def parseArgs : List String → Config → Except String Config
  | [], c => .ok c
  | "-o" :: d :: rest, c | "--out" :: d :: rest, c => parseArgs rest { c with out := d }
  | "-j" :: k :: rest, c | "--jobs" :: k :: rest, c => match k.toNat? with
    | some j => parseArgs rest { c with jobs := j }
    | none => .error s!"not a number: {k}"
  | "--name" :: s :: rest, c => parseArgs rest { c with name := s }
  | "--source" :: s :: rest, c => parseArgs rest { c with source := s }
  | "--no-source" :: rest, c => parseArgs rest { c with noSource := true }
  | a :: rest, c =>
    if a.startsWith "-" then .error s!"unknown option {a}"
    else parseArgs rest { c with modules := c.modules.push a.toName }

/-- The modules of the `.olean` files below `dir`. -/
partial def oleansBelow (dir : FilePath) (pre : Name) : IO (Array Name) := do
  let mut out := #[]
  for e in ← dir.readDir do
    if ← e.path.isDir then
      out := out ++ (← oleansBelow e.path (.str pre e.fileName))
    else if e.path.extension == some "olean" then
      if let some stem := e.path.fileStem then out := out.push (.str pre stem)
  return out

def pathOf (dir : FilePath) (m : Name) : FilePath :=
  m.components.foldl (init := dir) fun d c => d / c.toString (escape := false)

/-- The built modules to show. -/
def findModules (prefixes : Array Name) : IO (Array Name) := do
  if prefixes.isEmpty then
    let dir : FilePath := ".lake" / "build" / "lib" / "lean"
    unless ← dir.isDir do
      throw <| IO.userError "no .lake/build/lib/lean here: run this in a Lean project after `lake build`"
    return ← oleansBelow dir .anonymous
  let mut out := #[]
  for p in prefixes do
    let mut found := false
    for d in ← searchPathRef.get do
      let base := pathOf d p
      if ← (base.addExtension "olean").pathExists then
        out := out.push p
        found := true
      if ← base.isDir then
        out := out ++ (← oleansBelow base p)
        found := true
    unless found do throw <| IO.userError s!"no built module {p} (or {p}.*) found"
  return out.toList.eraseDups.toArray

/-- The modules among `mods` that declare `main` and that no other module of `mods` imports: the
roots of executables (e.g. build scripts). They are not shown, since two of them cannot be
imported together. (Lean does not free a failed import, so this is checked beforehand.) -/
unsafe def executableRoots (mods : Array Name) : IO (Array Name) := do
  let targets : Std.HashSet Name := .ofArray mods
  let mut imported : Std.HashSet Name := {}
  let mut withMain := #[]
  for m in mods do
    -- The public part (`.olean`) only: a `.olean.private` cannot be read on its own. The file
    -- is unmapped right away (only our own names are kept): `importModules` maps every module
    -- at a fixed address and has to copy it into memory when that address is taken.
    let (data, region) ← readModuleData (← findOLean m)
    for i in data.imports do
      if let some t := targets.get? i.module then imported := imported.insert t
    if data.constNames.contains `main then withMain := withMain.push m
    region.free
  return withMain.filter (!imported.contains ·)

def git (dir : FilePath) (args : Array String) : IO (Option String) := do
  let o ← IO.Process.output { cmd := "git", args := #["-C", dir.toString] ++ args }
  return if o.exitCode == 0 then some o.stdout.trimAscii.toString else none

/-- `https://github.com/OWNER/REPO/blob/COMMIT/<dir>/`, where `<dir>` is the source directory of
module `m` (from `LEAN_SRC_PATH`, set by `lake`), if it is in a git checkout from GitHub. -/
def githubSource (m : Name) : IO (Option String) := do
  let srcPath : List FilePath := match ← IO.getEnv "LEAN_SRC_PATH" with
    | some s => SearchPath.parse s
    | none => []
  let some dir ← (srcPath ++ [("." : FilePath)]).findM? fun d => (modToFilePath d m "lean").pathExists
    | return none
  let some top ← git dir #["rev-parse", "--show-toplevel"] | return none
  let some commit ← git dir #["rev-parse", "HEAD"] | return none
  let some url ← git dir #["remote", "get-url", "origin"] | return none
  let url := if url.endsWith ".git" then (url.dropEnd 4).toString else url
  let some repo := ["https://github.com/", "git@github.com:"].findSome? fun p =>
      if url.startsWith p then some (url.drop p.length).toString else none
    | IO.eprintln s!"note: {url} is not on GitHub, so the page shows no source"; return none
  let rel := ((← IO.FS.realPath dir).toString.drop (← IO.FS.realPath top).toString.length).toString
  let rel := (rel.dropWhile (· == '/')).toString
  if let some changes ← git dir #["status", "--porcelain", "--", "."] then
    unless changes.isEmpty do
      IO.eprintln s!"note: the page shows the source of commit {(commit.take 12).toString}, without your uncommitted changes"
  return some s!"https://github.com/{repo}/blob/{commit}/{if rel.isEmpty then "" else rel ++ "/"}"

unsafe def main (args : List String) : IO UInt32 := do
  if args.contains "-h" || args.contains "--help" then
    IO.println usage
    return 0
  let c ← match parseArgs args {} with
    | .ok c => pure c
    | .error e => IO.eprintln s!"depgraph: {e}\n\n{usage}"; return 1
  let jobs := if c.jobs > 0 then c.jobs else max 1 (System.Platform.Internal.getHardwareConcurrency ()).toNat
  let t0 ← IO.monoMsNow
  let log (s : String) : IO Unit := do IO.println s!"[{((← IO.monoMsNow) - t0) / 1000}s] {s}"
  initSearchPath (← findSysroot)
  let modules ← findModules c.modules
  if modules.isEmpty then
    IO.eprintln "depgraph: no modules found"
    return 1
  let cwd ← IO.currentDir
  let name := c.name.getD <| match c.modules[0]? with
    | some m => m.toString
    | none => (cwd.fileName.getD "library")
  let source ← if c.noSource then pure none else match c.source with
    | some s => pure (some s)
    | none => githubSource modules[0]!
  let roots ← executableRoots modules
  unless roots.isEmpty do
    IO.println s!"not shown, as they are the roots of executables: {", ".intercalate (roots.map toString).toList}"
  let modules := modules.filter (!roots.contains ·)
  log s!"importing {modules.size} modules"
  -- Two modules that declare the same name cannot be imported together; that happens with
  -- build scripts (e.g. two executables' `main`). Skip the module Lean reports and retry.
  let mut modules := modules
  let mut env? : Option Environment := none
  while env?.isNone do
    try
      env? := some (← importModules (modules.map fun m => { module := m, importAll := true }) {} (leakEnv := true))
    catch e =>
      let msg := toString e
      let some clash := (msg.splitOn " from ").getLast?.map (·.trimAscii.toString.toName)
        | throw e
      unless msg.contains "already contains" && modules.contains clash do throw e
      IO.eprintln s!"note: skipping {clash}, it declares a name another module also declares ({msg})"
      modules := modules.erase clash
  let some env := env? | unreachable!
  let g ← build env modules name jobs log
  log s!"writing the website to {c.out}"
  writeSite g c.out source
  log s!"done: {g.names.size} nodes, {g.out.foldl (· + ·.size) 0} edges"
  IO.println s!"\nTo view it: python3 -m http.server -d {c.out}  and open http://localhost:8000"
  if source.isNone then IO.println "(no source links: not a GitHub checkout; see --source)"
  return 0
