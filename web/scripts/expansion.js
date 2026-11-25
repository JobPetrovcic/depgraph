var unshowed = []

function unshowNode(v) {
  if (!nodes[v].shown && nodes[v].removed) return
  nodes[v].shown = false
  unshowed.push(v)
  collapse(v);
}

function showNode(v) {
  if (nodes[v].shown && !nodes[v].removed) return
  nodes[v].shown = true
  shownNodes.push(v)
}

// children of u that may be shown; options such as hiding internal declarations go here
function visibleChildren(u) {
  // library, namespace and module nodes also have module dependency edges (drawn by the option
  // "Display connections between modules"); they expand only into what they contain
  if ((graphManifest.generator == 'depgraph' || graphManifest.source) && isTreeNode(u)) return neighbours(u).filter(v => nodes[v].parent == u && !nodes[v].removed)
  return neighbours(u).filter(v => !nodes[v].removed)
}

function collapse(u) {
  if (!nodes[u].expanded) return

  nodes[u].expanded = false
  nodes[u].children = [];

  const out = visibleChildren(u)
  // order of bodies of for loops matters
  for (const v of out) {
    // update numberOfExpandedParents
    nodes[v].numberOfExpandedParents -= 1
  }
  for (const v of out) {
    if (
      nodes[v].numberOfExpandedParents == 0 &&
      !roots.includes(v)
    ) {
      unshowNode(v)
    }
  }
}

// loads what is needed and shows the children of u
async function expand(u) {
  // check if it is already expanded
  if (nodes[u].expanded) return

  await ensureAdjacency(u)
  const out = neighbours(u)
  await ensureNodes(out)

  nodes[u].expanded = true

  nodes[u].children = []

  for (const v of visibleChildren(u)) {
    // show neighbour and update numberOfExpandedParents
    nodes[v].numberOfExpandedParents += 1

    if (!nodes[v].shown) {
      showNode(v)

      nodes[u].children.push(v)

      // set intial position to parent; this will be the spawn position; once the positions are updated, this will be saved as old
      nodes[v].x = nodes[u].x
      nodes[v].y = nodes[u].y
    }
  }
}


// get some path from a root to u (parents were precomputed by the converter)
async function findSomePath(u) {
  let ret = [u]
  await ensureNodes([u])
  while (nodes[u].parent != -1) {
    u = nodes[u].parent
    await ensureNodes([u])
    ret.push(u)
  }
  return ret.reverse();
}

// function to expand a node with specified id (and some necessary parents so that there is a path from the root to it)
function expandById(nodeId) {
  return queueUpdate(() => expandByIdNow(nodeId))
}

async function expandByIdNow(nodeId) {
  await ensureNodes([nodeId])
  // if it is removed or already shown, return
  if (nodes[nodeId].removed) return

  if (!nodes[nodeId].shown) {
    let path = await findSomePath(nodeId)
    for (let i = 0; i < path.length - 1; ++i) {
      await expand(path[i]);
    }
    saveOldPositions();
    arrangeTree();
  }
  svg.transition().duration(duration).call(
    zoom.transform,
    d3.zoomIdentity.scale(1.3).translate(-nodes[nodeId].y, -nodes[nodeId].x)
  );
  update();
}
