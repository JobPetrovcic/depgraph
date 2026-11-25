import Lean
import DepGraph.Graph
import DepGraph.Web
open Lean System

/-! # Writing the website

The page loads the graph lazily, in chunks:

    graph_data.js              var graphManifest = {...}
    graph_data/n_<k>.json      {name:[], label:[], parent:[], nchild:[], in_degree:[], ...}
    graph_data/a_<k>.bin       out-neighbours of the chunk's nodes
    graph_data/r_<k>.bin       in-neighbours
    graph_data/names_<j>.json  all names, for the search

Chunk `k` holds the nodes `k * chunkSize ... (k+1) * chunkSize - 1`. Neighbour chunks (little
endian): uint32 rows; uint32 byteOffset[rows + 1]; then every row's neighbours, sorted, delta
coded and LEB128 encoded. -/

namespace DepGraph

def chunkSize := 1024
def namesPerFile := 100000
def topCount := 500

def jsonString (s : String) : String := "\"" ++ Json.escape s ++ "\""

def jsonArray (xs : Array String) : String := "[" ++ ",".intercalate xs.toList ++ "]"

/-- Four significant digits, e.g. `1234e-9`. -/
def float4 (x : Float) : String :=
  if x == 0 then "0" else
  let e := (Float.log10 x.abs).floor - 3
  let m := (x / Float.pow 10 e).round
  s!"{if x < 0 then "-" else ""}{m.abs.toUInt64}e{e.toInt64}"

def pushU32 (b : ByteArray) (v : Nat) : ByteArray :=
  b.push v.toUInt8 |>.push (v >>> 8).toUInt8 |>.push (v >>> 16).toUInt8 |>.push (v >>> 24).toUInt8

def pushVarint (b : ByteArray) (v : Nat) : ByteArray := Id.run do
  let mut b := b
  let mut v := v
  while v ≥ 128 do
    b := b.push (v % 128 + 128).toUInt8
    v := v / 128
  return b.push v.toUInt8

def encodeRows (adj : Array (Array Nat)) (lo hi : Nat) : ByteArray := Id.run do
  let mut data := ByteArray.empty
  let mut offsets := #[]
  for u in [lo:hi] do
    offsets := offsets.push data.size
    let mut prev := 0
    for v in adj[u]! do
      data := pushVarint data (v - prev)
      prev := v
  offsets := offsets.push data.size
  let mut b := pushU32 ByteArray.empty (hi - lo)
  for o in offsets do
    b := pushU32 b o
  return b ++ data

/-- Writes the website for `g` to `out`; `source`: GitHub URL of the library's source directory. -/
def writeSite (g : Graph) (out : FilePath) (source : Option String) : IO Unit := do
  let n := g.names.size
  let dir := out / "graph_data"
  IO.FS.createDirAll dir
  for e in ← dir.readDir do
    if e.path.extension == some "json" || e.path.extension == some "bin" then IO.FS.removeFile e.path
  let labels := (g.labels.toList.eraseDups.toArray).qsort (· < ·)
  let labelIdx : Std.HashMap String Nat := labels.zipIdx.foldl (fun m (l, i) => m.insert l i) {}
  let mut inAdj : Array (Array Nat) := Array.replicate n #[]
  for u in [0:n] do
    for v in g.out[u]! do
      inAdj := inAdj.modify v (·.push u)
  let chunks := (n + chunkSize - 1) / chunkSize
  for k in [0:chunks] do
    let lo := k * chunkSize
    let hi := min n (lo + chunkSize)
    let col (f : Nat → String) := jsonArray ((Array.range (hi - lo)).map (f <| lo + ·))
    let table := "{" ++ ",".intercalate [
      "\"name\":" ++ col (jsonString g.names[·]!),
      "\"label\":" ++ col (toString labelIdx[g.labels[·]!]!),
      "\"parent\":" ++ col (toString g.parent[·]!),
      "\"nchild\":" ++ col (toString g.out[·]!.size),
      "\"in_degree\":" ++ col (toString g.inDegree[·]!),
      "\"out_degree\":" ++ col (toString g.outDegree[·]!),
      "\"pagerank\":" ++ col (float4 g.pagerank[·]!),
      "\"range\":" ++ col (fun u => match g.range[u]! with
        | some (a, b) => s!"[{a},{b}]"
        | none => "null")] ++ "}"
    IO.FS.writeFile (dir / s!"n_{k}.json") table
    IO.FS.writeBinFile (dir / s!"a_{k}.bin") (encodeRows g.out lo hi)
    IO.FS.writeBinFile (dir / s!"r_{k}.bin") (encodeRows inAdj lo hi)
  let namesFiles := (n + namesPerFile - 1) / namesPerFile
  for j in [0:namesFiles] do
    let names := g.names.extract (j * namesPerFile) ((j + 1) * namesPerFile)
    IO.FS.writeFile (dir / s!"names_{j}.json") (jsonArray (names.map jsonString))
  let top := ((Array.range n).qsort fun a b =>
    g.inDegree[a]! > g.inDegree[b]! || (g.inDegree[a]! == g.inDegree[b]! && a < b)).extract 0 topCount
  let edges := g.out.foldl (· + ·.size) 0
  let manifest := "{" ++ ",".intercalate ([
    "\"version\":3", "\"format\":\"bin1\"",
    s!"\"chunkSize\":{chunkSize}", s!"\"namesFiles\":{namesFiles}",
    s!"\"nodeCount\":{n}", s!"\"edgeCount\":{edges}",
    "\"labels\":" ++ jsonArray (labels.map jsonString),
    "\"stats\":[\"in_degree\",\"out_degree\",\"pagerank\"]",
    "\"root\":0", "\"roots\":[{\"id\":0,\"name\":" ++ jsonString g.names[0]! ++ "}]",
    "\"topIndegree\":" ++ jsonArray (top.map fun u => s!"[{u},{jsonString g.names[u]!},{g.inDegree[u]!}]")]
    ++ (source.map (s!"\"source\":{jsonString ·}")).toList) ++ "}"
  IO.FS.writeFile (out / "graph_data.js") s!"var graphManifest = {manifest};\n"
  for (path, text) in webFiles do
    let file := out / path
    if let some p := file.parent then IO.FS.createDirAll p
    IO.FS.writeFile file text

end DepGraph
