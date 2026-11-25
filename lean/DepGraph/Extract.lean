import Lean
open Lean System

/-! # The declarations of Lean modules, in the depgraph format (FORMAT.md) -/

namespace DepGraph

/-- The kind of a declaration. -/
def kindOf : ConstantInfo → String
  | .axiomInfo _ => "axiom"
  | .defnInfo _ => "function"
  | .thmInfo _ => "theorem"
  | .opaqueInfo _ => "abstract"
  | .quotInfo _ => "quot-info"
  | .inductInfo _ => "data"
  | .ctorInfo _ => "constructor"
  | .recInfo _ => "recursor"

/-- The constants a declaration uses: in its type and value (proof, body), an inductive type's
constructors, and a constructor's inductive type. -/
def usedConstants (c : ConstantInfo) : Array Name :=
  let t := c.type.getUsedConstants
  match c with
  | .defnInfo v => t ++ v.value.getUsedConstants
  | .thmInfo v => t ++ v.value.getUsedConstants
  | .opaqueInfo v => t ++ v.value.getUsedConstants
  | .inductInfo v => t ++ v.ctors.toArray
  | .ctorInfo v => t.push v.induct
  | _ => t

/-- Runs `work i` for every `i < n` on `jobs` dedicated threads, each taking the next index
from a shared counter. Results are returned in index order. -/
def parallelFor {α : Type} [Inhabited α] (jobs n : Nat) (work : Nat → IO α) : IO (Array α) := do
  let next ← IO.mkRef 0
  let worker : IO (Array (Nat × α)) := do
    let mut acc := #[]
    repeat
      let i ← next.modifyGet fun i => (i, i + 1)
      if i ≥ n then break
      acc := acc.push (i, ← work i)
    return acc
  let tasks ← (List.range jobs).mapM fun _ => IO.asTask worker .dedicated
  let mut results := Array.replicate n default
  for t in tasks do
    for (i, r) in ← IO.ofExcept (← IO.wait t) do
      results := results.set! i r
  return results

/-- The source range of a declaration Lean recorded none for (auxiliary ones such as `f._proof_1`,
`f.eq_1`, `_private.M.0.f.match_1`): that of its nearest name prefix in the same module. -/
def inheritedRange (own : Std.HashMap Name (Nat × Nat)) (n : Name) : Option (Nat × Nat) := Id.run do
  for c in [n, (privateToUserName? n).getD .anonymous] do
    let mut p := c
    while !p.isAnonymous do
      p := p.getPrefix
      if let some r := own[p]? then return some r
  return none

def jsonString (s : String) : String := "\"" ++ Json.escape s ++ "\""

/-- The lines of module `m` (module index `idx` in `env`, source file `file`) and of its
declarations; their uses are restricted to the declarations `shown`. -/
def moduleLines (env : Environment) (shown : Std.HashSet Name) (m : Name) (idx : Nat)
    (file : Option FilePath) : String := Id.run do
  let consts := env.header.moduleData[idx]!.constants
  let mut own : Std.HashMap Name (Nat × Nat) := {}
  for c in consts do
    if let some r := declRangeExt.find? env c.name then
      own := own.insert c.name (r.range.pos.line, r.range.endPos.line)
  let mname := jsonString m.toString
  let mut s := "{\"module\":" ++ mname
  if let some f := file then s := s ++ ",\"file\":" ++ jsonString f.toString
  s := s ++ "}\n"
  for c in consts do
    let mut uses : Std.HashSet Name := {}
    for u in usedConstants c do
      if u != c.name && shown.contains u then uses := uses.insert u
    s := s ++ "{\"decl\":" ++ jsonString c.name.toString ++ ",\"module\":" ++ mname ++
      ",\"kind\":\"" ++ kindOf c ++ "\""
    if let some (a, b) := own[c.name]? <|> inheritedRange own c.name then
      s := s ++ s!",\"line\":{a},\"end\":{b}"
    s := s ++ ",\"uses\":[" ++ ",".intercalate (uses.toList.map (jsonString ·.toString)) ++ "]}\n"
  return s

/-- Writes the header and the lines of `modules` (with their source files) to `h`. -/
unsafe def writeDecls (env : Environment) (modules : Array (Name × Option FilePath)) (libName : String)
    (jobs : Nat) (h : IO.FS.Stream) : IO Unit := do
  -- module index in `env` (`Environment.getModuleIdx?` searches linearly)
  let modIdx : Std.HashMap Name Nat :=
    env.header.moduleNames.zipIdx.foldl (fun m (n, i) => m.insert n i) {}
  let idxs ← modules.mapM fun (m, _) => match modIdx[m]? with
    | some i => pure i
    | none => throw <| IO.userError s!"{m}: not imported"
  h.putStr ("{\"depgraph\":1,\"library\":" ++ jsonString libName ++ "}\n")
  -- shared read-only data is marked persistent: no reference counting across threads
  let envP ← Runtime.markPersistent env
  -- (not by `env.getModuleIdxFor?`: auxiliary lemmas, e.g. `f.hcongr_2`, are in several modules)
  let shown : Std.HashSet Name := idxs.foldl (init := {}) fun s i =>
    env.header.moduleData[i]!.constants.foldl (fun s c => s.insert c.name) s
  let shownP ← Runtime.markPersistent shown
  let chunks ← parallelFor jobs modules.size fun k =>
    pure (moduleLines envP shownP modules[k]!.1 idxs[k]! modules[k]!.2)
  for c in chunks do
    h.putStr c
  h.flush

end DepGraph
