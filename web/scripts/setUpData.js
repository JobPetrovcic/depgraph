// Lazily loaded graph data; the format is described in convert_to_js.py.
// graph_data.js (loaded before this file) defines graphManifest; node tables ("n", JSON),
// out-neighbour lists ("a", binary), in-neighbour lists ("r", binary) and the full name list
// ("names") are fetched per chunk of chunkSize node ids.
const graphDataDir = 'graph_data/' // next to graph_data.js, relative to the page
const chunkSize = graphManifest.chunkSize
const numberOfNodes = graphManifest.nodeCount

var nodes = new Array(numberOfNodes) // node objects, created when their "n" chunk arrives
var shownNodes = []
const nodeChunks = [], adjacencyChunks = [], reverseChunks = []
var allNames = null
const chunkPromises = new Map()   // "kind_k" -> Promise
const extraNeighbours = new Map() // id -> [ids] added by InitiallyConnect

function chunkOf(id) {
  return Math.floor(id / chunkSize)
}

// binary edge chunk: uint32 rows, uint32 byteOffset[rows+1], varint-coded deltas per row
function parseEdgeChunk(buffer) {
  const rows = new DataView(buffer).getUint32(0, true)
  return {
    off: new Uint32Array(buffer, 4, rows + 1),
    bytes: new Uint8Array(buffer, 4 + 4 * (rows + 1)),
  }
}

function graphChunk(kind, k, payload) {
  if (kind == 'n') {
    nodeChunks[k] = payload
    createNodes(k, payload)
  } else if (kind == 'a') {
    adjacencyChunks[k] = parseEdgeChunk(payload)
  } else if (kind == 'r') {
    reverseChunks[k] = parseEdgeChunk(payload)
  } else if (kind == 'names') {
    nameParts[k] = payload
  }
}
const nameParts = []

function loadChunk(kind, k) {
  const key = kind + '_' + k
  if (chunkPromises.has(key)) return chunkPromises.get(key)
  const binary = kind == 'a' || kind == 'r'
  const url = graphDataDir + key + (binary ? '.bin' : '.json')
  const promise = fetch(url)
    .then(response => {
      if (!response.ok) throw new Error('could not load ' + url + ': ' + response.status)
      return binary ? response.arrayBuffer() : response.json()
    })
    .then(payload => graphChunk(kind, k, payload))
  chunkPromises.set(key, promise)
  return promise
}

function createNodes(k, table) {
  const base = k * chunkSize
  for (let j = 0; j < table.name.length; j++) {
    const node = {
      id: base + j,
      name: table.name[j],
      label: graphManifest.labels[table.label[j]],
      parent: table.parent[j],
      nchild: table.nchild[j],
      shown: false,
      expanded: false,
      removed: false,
      numberOfExpandedParents: 0,
      children: [],
      x: 0, y: 0, x0: 0, y0: 0,
    }
    for (const key of graphManifest.stats) node[key] = table[key][j]
    if (table.range) node.range = table.range[j] // [line, end_line] in the module's file, or null
    if (InitiallyRemoveNodes.includes(node.name)) node.removed = true
    nodes[base + j] = node
  }
}

// make sure the node objects for these ids exist
function ensureNodes(ids) {
  const needed = new Set()
  for (const id of ids) if (nodes[id] === undefined) needed.add(chunkOf(id))
  return Promise.all([...needed].map(k => loadChunk('n', k)))
}

function ensureAdjacency(u) {
  const k = chunkOf(u)
  return adjacencyChunks[k] ? Promise.resolve() : loadChunk('a', k)
}

function ensureReverse(u) {
  const k = chunkOf(u)
  return reverseChunks[k] ? Promise.resolve() : loadChunk('r', k)
}

// the full name list comes in graphManifest.namesFiles parts
function ensureAllNames() {
  if (allNames) return Promise.resolve()
  const parts = []
  for (let j = 0; j < graphManifest.namesFiles; j++) parts.push(loadChunk('names', j))
  return Promise.all(parts).then(() => { allNames = [].concat(...nameParts) })
}

// decode one row of an edge chunk: ascending ids, delta coded, LEB128 varints
function csrRow(chunks, u) {
  const c = chunks[chunkOf(u)]
  const j = u % chunkSize
  const bytes = c.bytes
  let p = c.off[j]
  const end = c.off[j + 1]
  const out = []
  let previous = 0
  while (p < end) {
    let value = 0, shift = 0, b
    do {
      b = bytes[p++]
      value |= (b & 0x7f) << shift
      shift += 7
    } while (b & 0x80)
    previous += value
    out.push(previous)
  }
  return out
}

// out-neighbours of u (its adjacency chunk must be loaded)
function neighbours(u) {
  const out = csrRow(adjacencyChunks, u)
  const extra = extraNeighbours.get(u)
  return extra ? out.concat(extra) : out
}

// in-neighbours of u (its reverse chunk must be loaded)
function reverseNeighbours(u) {
  return csrRow(reverseChunks, u)
}

// roots: nodes without incoming edges; the main library is first
var roots = graphManifest.roots.map(r => r.id)
var rootid = graphManifest.root
if (typeof rootName !== 'undefined') {
  const named = graphManifest.roots.find(r => r.name == rootName)
  if (named) rootid = named.id
}

// library specific connections (see librarySpecificSettings.js): u -> v by node name
async function applyInitiallyConnect() {
  if (InitiallyConnect.length == 0) return
  function findLoaded(name) {
    for (const node of nodes) if (node !== undefined && node.name == name) return node.id
    return -1
  }
  for (const [uName, vName] of InitiallyConnect) {
    let u = findLoaded(uName), v = findLoaded(vName)
    if (u < 0 || v < 0) {
      await ensureAllNames()
      if (u < 0) u = allNames.indexOf(uName)
      if (v < 0) v = allNames.indexOf(vName)
      if (u < 0 || v < 0) continue
      await ensureNodes([u, v])
    }
    await ensureAdjacency(u)
    if (neighbours(u).includes(v)) continue
    extraNeighbours.set(u, (extraNeighbours.get(u) || []).concat([v]))
    nodes[u].nchild += 1
    roots = roots.filter(r => r != v)
  }
}

// which nodes depend on the observed one (reverse reachability); filled by getDependencyOn
var dependsOn = new Uint8Array(numberOfNodes)
var isSomeObserved = false

async function getDependencyOn(queryNodeId) {
  dependsOn = new Uint8Array(numberOfNodes)
  dependsOn[queryNodeId] = 1
  const stack = [queryNodeId]
  while (stack.length > 0) {
    const u = stack.pop()
    await ensureReverse(u)
    for (const v of reverseNeighbours(u)) {
      if (!dependsOn[v]) {
        dependsOn[v] = 1
        stack.push(v)
      }
    }
  }
}
