import Lean
open Lean

/-! # The dependency graph

Nodes: the library (id 0), then namespaces (folders) and modules, numbered breadth-first, then
the declarations, grouped by module in module order. An edge `A → B` means "A uses B". Folders
and modules have edges to what they contain and to the modules their declarations use. -/

namespace DepGraph

/-- The page's label of a declaration's kind. -/
def kindOf : ConstantInfo → String
  | .axiomInfo _ => ":axiom"
  | .defnInfo _ => ":function"
  | .thmInfo _ => ":theorem"
  | .opaqueInfo _ => ":abstract"
  | .quotInfo _ => ":quot-info"
  | .inductInfo _ => ":data"
  | .ctorInfo _ => ":constructor"
  | .recInfo _ => ":recursor"

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

/-- Sorted, without duplicates. -/
def sortDedup (a : Array Nat) : Array Nat := Id.run do
  let a := a.qsort (· < ·)
  let mut out := Array.mkEmpty a.size
  for x in a do
    if out.back? != some x then out := out.push x
  return out

def lastComponent : Name → String
  | .str _ s => s
  | .num _ k => toString k
  | .anonymous => ""

structure Graph where
  /-- number of library/folder/module nodes; they have the ids `0 .. treeCount - 1` -/
  treeCount : Nat
  names : Array String
  labels : Array String
  /-- the containing node, `-1` for the library -/
  parent : Array Int
  /-- declarations: first and last line of their source -/
  range : Array (Option (Nat × Nat))
  /-- out-neighbours, sorted -/
  out : Array (Array Nat)
  inDegree : Array Nat
  outDegree : Array Nat
  pagerank : Array Float

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

/-! ## Folders and modules -/

structure Tree where
  names : Array String
  labels : Array String
  parent : Array Nat
  index : Std.HashMap Name Nat := {}

/-- The node of module or folder `n`, created with its ancestors if needed. -/
partial def treeNode (n : Name) (label : String) : StateM Tree Nat := do
  if let some i := (← get).index[n]? then
    if label == ":module" then modify fun t => { t with labels := t.labels.set! i label }
    return i
  let p ← match n with
    | .str pre _ | .num pre _ => if pre.isAnonymous then pure 0 else treeNode pre ":namespace"
    | .anonymous => pure 0
  let i := (← get).names.size
  -- `modify`, not `get`/`set`: the arrays stay unshared and are extended in place
  modify fun t => { t with names := t.names.push (lastComponent n), labels := t.labels.push label,
                           parent := t.parent.push p, index := t.index.insert n i }
  return i

/-- New ids in breadth-first order from node 0 (parents come before children, and the children
of a node get consecutive ids). -/
def bfsOrder (parent : Array Nat) : Array Nat := Id.run do
  let n := parent.size
  let mut children : Array (Array Nat) := Array.replicate n #[]
  for v in [1:n] do
    children := children.modify parent[v]! (·.push v)
  let mut newId := Array.replicate n 0
  let mut queue := #[0]
  let mut head := 0
  while h : head < queue.size do
    let u := queue[head]
    newId := newId.set! u head
    head := head + 1
    queue := queue ++ children[u]!
  return newId

/-! ## Building the graph -/

structure Decl where
  info : ConstantInfo
  /-- tree node (new id) of its module -/
  module : Nat
  range : Option (Nat × Nat)
  deriving Inhabited

/-- The source range of a declaration Lean recorded none for (auxiliary ones such as `f._proof_1`,
`f.eq_1`, `_private.M.0.f.match_1`): that of its nearest name prefix in the same module. -/
def inheritedRange (own : Std.HashMap Name (Nat × Nat)) (n : Name) : Option (Nat × Nat) := Id.run do
  for c in [n, (privateToUserName? n).getD .anonymous] do
    let mut p := c
    while !p.isAnonymous do
      p := p.getPrefix
      if let some r := own[p]? then return some r
  return none

def pagerankOf (n : Nat) (outDeg : Array Nat) (inAdj : Array (Array Nat)) : Array Float := Id.run do
  let d := 0.85
  let nf := n.toFloat
  let mut pr : Array Float := Array.replicate n (1.0 / nf)
  for _ in [0:200] do
    let mut dangling := 0.0
    let mut share : Array Float := Array.mkEmpty n
    for u in [0:n] do
      let k := outDeg[u]!
      if k == 0 then
        dangling := dangling + pr[u]!
        share := share.push 0.0
      else
        share := share.push (pr[u]! / k.toFloat)
    let base := (1.0 - d) / nf + d * dangling / nf
    let mut next : Array Float := Array.mkEmpty n
    let mut diff := 0.0
    for v in [0:n] do
      let mut s := 0.0
      for u in inAdj[v]! do
        s := s + share[u]!
      let x := base + d * s
      diff := diff + (x - pr[v]!).abs
      next := next.push x
    pr := next
    if diff < 1e-10 then break
  return pr

/-- The graph of the declarations of `modules`, which must be in `env`. -/
unsafe def build (env : Environment) (modules : Array Name) (libName : String) (jobs : Nat)
    (log : String → IO Unit) : IO Graph := do
  -- folders and modules
  let modules := modules.qsort (·.toString < ·.toString)
  let (moduleNode, tree) := (modules.mapM (treeNode · ":module")).run
    { names := #[s!"library_{libName}"], labels := #[":library"], parent := #[0] }
  let newId := bfsOrder tree.parent
  let T := tree.names.size
  let mut oldOf := Array.replicate T 0
  for i in [0:T] do
    oldOf := oldOf.set! newId[i]! i
  let moduleNode := moduleNode.map (newId[·]!)
  -- modules in node order, and their declarations (the first module declaring a name wins)
  let order := (Array.range modules.size).qsort (moduleNode[·]! < moduleNode[·]!)
  -- module index in `env` (`Environment.getModuleIdx?` searches linearly)
  let modIdx : Std.HashMap Name Nat :=
    env.header.moduleNames.zipIdx.foldl (fun m (n, i) => m.insert n i) {}
  let mut decls : Array Decl := #[]
  let mut declId : Std.HashMap Name Nat := {}
  let mut moduleStart : Array Nat := #[]
  for mi in order do
    moduleStart := moduleStart.push decls.size
    let some idx := modIdx[modules[mi]!]? | throw <| IO.userError s!"{modules[mi]!}: not imported"
    let first := decls.size
    let mut own : Std.HashMap Name (Nat × Nat) := {}
    for c in env.header.moduleData[idx]!.constants do
      if declId.contains c.name then continue
      let range := (declRangeExt.find? env c.name).map fun r => (r.range.pos.line, r.range.endPos.line)
      if let some r := range then own := own.insert c.name r
      declId := declId.insert c.name decls.size
      decls := decls.push { info := c, module := moduleNode[mi]!, range }
    for i in [first:decls.size] do
      if decls[i]!.range.isNone then
        decls := decls.modify i fun d => { d with range := inheritedRange own d.info.name }
  moduleStart := moduleStart.push decls.size
  let D := decls.size
  log s!"{T} folders and modules, {D} declarations"
  -- dependencies, in parallel over modules (read-only shared data is marked persistent:
  -- no reference counting across threads)
  let declIdP ← Runtime.markPersistent declId
  let declsP ← Runtime.markPersistent decls
  let perModule ← parallelFor jobs order.size fun k => do
    let mut res : Array (Array Nat) := #[]
    for i in [moduleStart[k]!:moduleStart[k+1]!] do
      let targets := (usedConstants declsP[i]!.info).filterMap fun c =>
        match declIdP[c]? with
        | some j => if j == i then none else some j
        | none => none
      res := res.push (sortDedup targets)
    return res
  let deps : Array (Array Nat) := perModule.flatten
  let edges := deps.foldl (· + ·.size) 0
  log s!"{edges} dependencies between declarations"
  -- statistics of the declaration graph
  let outDeg := deps.map (·.size)
  let mut inAdj : Array (Array Nat) := Array.replicate D #[]
  for u in [0:D] do
    for v in deps[u]! do
      inAdj := inAdj.modify v (·.push u)
  let pr := pagerankOf D outDeg inAdj
  -- module dependencies
  let mut moduleDeps : Array (Array Nat) := Array.replicate T #[]
  for u in [0:D] do
    let m := decls[u]!.module
    for v in deps[u]! do
      let m' := decls[v]!.module
      if m' != m then moduleDeps := moduleDeps.modify m (·.push m')
  -- the whole graph
  let mut out : Array (Array Nat) := Array.mkEmpty (T + D)
  let mut childrenOf : Array (Array Nat) := Array.replicate T #[]
  for v in [1:T] do
    childrenOf := childrenOf.modify newId[tree.parent[oldOf[v]!]!]! (·.push v)
  let mut declsOf : Array (Nat × Nat) := Array.replicate T (0, 0)
  for k in [0:order.size] do
    declsOf := declsOf.set! moduleNode[order[k]!]! (moduleStart[k]!, moduleStart[k+1]!)
  for u in [0:T] do
    let (a, b) := declsOf[u]!
    out := out.push (sortDedup (childrenOf[u]! ++ (Array.range (b - a)).map (· + a + T) ++ moduleDeps[u]!))
  for u in [0:D] do
    out := out.push (deps[u]!.map (· + T))
  let mut inDegree := Array.replicate (T + D) 0
  for u in [0:T + D] do
    for v in out[u]! do
      inDegree := inDegree.modify v (· + 1)
  return {
    treeCount := T
    names := (Array.range T).map (tree.names[oldOf[·]!]!) ++ decls.map (·.info.name.toString)
    labels := (Array.range T).map (tree.labels[oldOf[·]!]!) ++ decls.map (kindOf ·.info)
    parent := (Array.range T).map (fun v => if v == 0 then -1 else (newId[tree.parent[oldOf[v]!]!]! : Int))
      ++ decls.map (fun d => (d.module : Int))
    range := Array.replicate T none ++ decls.map (·.range)
    out
    -- declarations: degrees in the declaration graph; folders and modules: in the whole graph
    inDegree := (Array.range T).map (inDegree[·]!) ++ (Array.range D).map (inAdj[·]!.size)
    outDegree := (Array.range T).map (out[·]!.size) ++ outDeg
    pagerank := Array.replicate T 0.0 ++ pr
  }

end DepGraph
