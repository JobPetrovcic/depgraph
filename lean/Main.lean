import Lean
import DepGraph.Extract
open Lean System DepGraph

def version : String := "0.3.0"

def usage : String := "usage: lake exe depgraph [options] [MODULE...]

Writes a website showing the dependency graph of a Lean library: by default of the
current project (the modules it has built, in .lake/build/lib/lean), otherwise of the
modules MODULE and MODULE.* (e.g. Mathlib). Build the modules first (`lake build`).

  -o, --out DIR    output directory (default: .lake/depgraph)
  -j, --jobs N     threads (default: all cores)
  --name NAME      name of the library (default: the first MODULE or the directory)
  --source URL     source of the modules on GitHub, e.g.
                   https://github.com/OWNER/REPO/blob/COMMIT/src/ (default: found with git)
  --no-source      do not link the source
  --export FILE    only write the declarations to FILE, in the depgraph format (FORMAT.md)"

structure Config where
  modules : Array Name := #[]
  out : FilePath := ".lake" / "depgraph"
  jobs : Nat := 0
  name : Option String := none
  source : Option String := none
  noSource : Bool := false
  exportFile : Option FilePath := none

def parseArgs : List String → Config → Except String Config
  | [], c => .ok c
  | "-o" :: d :: rest, c | "--out" :: d :: rest, c => parseArgs rest { c with out := d }
  | "-j" :: k :: rest, c | "--jobs" :: k :: rest, c => match k.toNat? with
    | some j => parseArgs rest { c with jobs := j }
    | none => .error s!"not a number: {k}"
  | "--name" :: s :: rest, c => parseArgs rest { c with name := s }
  | "--source" :: s :: rest, c => parseArgs rest { c with source := s }
  | "--no-source" :: rest, c => parseArgs rest { c with noSource := true }
  | "--export" :: f :: rest, c => parseArgs rest { c with exportFile := some f }
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

/-- The source file of module `m`, found in `LEAN_SRC_PATH` (set by `lake`) or here. -/
def sourceFile (srcPath : List FilePath) (m : Name) : IO (Option FilePath) := do
  for d in srcPath ++ [("." : FilePath)] do
    let f := modToFilePath d m "lean"
    if ← f.pathExists then return some (← IO.FS.realPath f)
  return none

/-- The program that writes the website (`depgraph`, in Rust): `DEPGRAPH_BIN`, or this
version's release from GitHub, downloaded once into the user's cache directory. -/
def siteTool : IO FilePath := do
  if let some p ← IO.getEnv "DEPGRAPH_BIN" then return p
  let t := System.Platform.target
  let arch := if t.startsWith "x86_64" then "x86_64"
    else if t.startsWith "aarch64" || t.startsWith "arm64" then "aarch64" else t
  let os := if System.Platform.isWindows then "windows" else if System.Platform.isOSX then "macos" else "linux"
  let exe := if System.Platform.isWindows then ".exe" else ""
  let cache ← match ← IO.getEnv "XDG_CACHE_HOME", ← IO.getEnv "LOCALAPPDATA", ← IO.getEnv "HOME" with
    | some d, _, _ | none, some d, _ => pure (FilePath.mk d)
    | none, none, some h => pure (FilePath.mk h / ".cache")
    | none, none, none => pure (FilePath.mk ".lake")
  let dir := cache / "depgraph" / version
  let bin := dir / s!"depgraph{exe}"
  if ← bin.pathExists then return bin
  let url := s!"https://github.com/JobPetrovcic/depgraph/releases/download/v{version}/depgraph-{arch}-{os}{exe}"
  IO.println s!"downloading {url}"
  IO.FS.createDirAll dir
  let part := bin.addExtension "part"
  let o ← IO.Process.output { cmd := "curl", args := #["-fsSL", "-o", part.toString, url] }
  unless o.exitCode == 0 do
    throw <| IO.userError s!"could not download {url} ({o.stderr.trimAscii}). Build it with \
      `cargo install --git https://github.com/JobPetrovcic/depgraph --tag v{version}` and set \
      DEPGRAPH_BIN to its path."
  let rwx : IO.AccessRight := { read := true, write := true, execution := true }
  IO.setAccessRights part { user := rwx, group := { rwx with write := false }, other := { rwx with write := false } }
  IO.FS.rename part bin
  return bin

unsafe def main (args : List String) : IO UInt32 := do
  if args.contains "-h" || args.contains "--help" then
    IO.println usage
    return 0
  let c ← match parseArgs args {} with
    | .ok c => pure c
    | .error e => IO.eprintln s!"depgraph: {e}\n\n{usage}"; return 1
  let jobs := if c.jobs > 0 then c.jobs else max 1 (System.Platform.Internal.getHardwareConcurrency ()).toNat
  let t0 ← IO.monoMsNow
  let log (s : String) : IO Unit := do
    IO.println s!"[{((← IO.monoMsNow) - t0) / 1000}s] {s}"
    (← IO.getStdout).flush
  initSearchPath (← findSysroot)
  let modules ← findModules c.modules
  if modules.isEmpty then
    IO.eprintln "depgraph: no modules found"
    return 1
  let cwd ← IO.currentDir
  let name := c.name.getD <| match c.modules[0]? with
    | some m => m.toString
    | none => cwd.fileName.getD "library"
  let roots ← executableRoots modules
  unless roots.isEmpty do
    IO.println s!"not shown, as they are the roots of executables: {", ".intercalate (roots.map toString).toList}"
  let modules := modules.filter (!roots.contains ·)
  -- the site tool first: if it cannot be found, fail before the long part
  let tool ← if c.exportFile.isSome then pure none else some <$> siteTool
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
  -- source files: local paths (the site tool finds their GitHub repository), or relative to --source
  let srcPath : List FilePath := match ← IO.getEnv "LEAN_SRC_PATH" with
    | some s => SearchPath.parse s
    | none => []
  let withFiles ← modules.mapM fun m => do
    if c.noSource then return (m, none)
    if c.source.isSome then return (m, some (modToFilePath "" m "lean"))
    return (m, ← sourceFile srcPath m)
  log s!"writing the declarations"
  match c.exportFile, tool with
  | some f, _ =>
    let h ← IO.FS.Handle.mk f .write
    writeDecls env withFiles name jobs (.ofHandle h)
    log s!"wrote {f}"
    return 0
  | none, some tool =>
    let toolArgs := #["-o", c.out.toString, "-j", toString jobs] ++
      (if c.noSource then #["--no-source"] else #[]) ++ (match c.source with | some s => #["--source", s] | none => #[])
    let child ← IO.Process.spawn { cmd := tool.toString, args := toolArgs, stdin := .piped }
    let (stdin, child) ← child.takeStdin
    writeDecls env withFiles name jobs (.ofHandle stdin)
    let code ← child.wait
    unless code == 0 do return code
    IO.println s!"\nTo view it: python3 -m http.server -d {c.out}  and open http://localhost:8000"
    return 0
  | none, none => unreachable!
