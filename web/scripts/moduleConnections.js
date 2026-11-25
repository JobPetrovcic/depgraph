// Option "Display connections between modules": draws the module -> module dependency edges of the
// data between the shown library/namespace/module nodes ("tree nodes"), lifted to the nearest
// shown ancestor (a collapsed folder stands for all modules below it).
// Assumes, as written by the leangraph converter, that the tree nodes have the smallest ids.
var showModuleConnections = false
var treeNodeCount = 0       // ids 0 .. treeNodeCount-1 are tree nodes
var moduleDependencies = null // CSR over tree nodes: {off, target}
const treeNodeLabels = [':library', ':namespace', ':module', ':external-library', ':external-module']

function isTreeNode(u) {
  return treeNodeLabels.includes(nodes[u].label)
}

async function ensureModuleDependencies() {
  if (moduleDependencies) return
  let count = 0
  while (count < numberOfNodes) {
    await ensureNodes([count])
    if (!isTreeNode(count)) break
    count++
  }
  const loads = []
  for (let k = 0; k * chunkSize < count; k++) loads.push(ensureAdjacency(k * chunkSize))
  await Promise.all(loads)
  const off = new Int32Array(count + 1), target = []
  for (let u = 0; u < count; u++) {
    for (const v of neighbours(u)) {
      if (v < count && nodes[v].parent != u) target.push(v)
    }
    off[u + 1] = target.length
  }
  treeNodeCount = count
  moduleDependencies = { off, target: Int32Array.from(target) }
}

// dependency links between shown tree nodes, with the number of module pairs they stand for
function moduleDependencyLinks() {
  const T = treeNodeCount, { off, target } = moduleDependencies
  const shownAs = new Int32Array(T) // nearest shown ancestor-or-self, -1 if none
  for (let u = 0; u < T; u++) {
    const p = nodes[u].parent
    shownAs[u] = nodes[u].shown && !nodes[u].removed ? u : (p >= 0 && p < u ? shownAs[p] : -1)
  }
  const counts = new Map()
  for (let u = 0; u < T; u++) {
    const a = shownAs[u]
    if (a < 0) continue
    for (let j = off[u]; j < off[u + 1]; j++) {
      const b = shownAs[target[j]]
      if (b < 0 || b == a) continue
      const key = a * T + b
      counts.set(key, (counts.get(key) || 0) + 1)
    }
  }
  const links = []
  for (const [key, count] of counts) {
    const link = linkObject(Math.floor(key / T), key % T, 'dependency')
    link.count = count
    links.push(link)
  }
  return links
}

// emphasise the dependency links of the hovered node (null: none)
function focusDependencyLinks(node) {
  d3.select('.allLinks').selectAll('path.links')
    .filter(d => d.dependency)
    .each(d => { d.focus = node === null ? null : d.source === node ? 'out' : d.target === node ? 'in' : null })
    .call(setLinkAttributes)
    .filter(d => d.focus)
    .raise()
}

function setShowModuleConnections(on) {
  return queueUpdate(async () => {
    if (on) await ensureModuleDependencies()
    showModuleConnections = on
    update()
  })
}
