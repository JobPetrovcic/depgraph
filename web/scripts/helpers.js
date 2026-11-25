function getColourFromPalette(label) {
  if (colorPalette[label] == null) {
    return colorUnknownLabel
  } else {
    return colorPalette[label]
  }
}

function setNodeColor(node) {
  if (node.expanded || node.nchild == 0) {
    return d3.color(getColourFromPalette(node.label)).darker(2)
  } else {
    return d3.color(getColourFromPalette(node.label))
  }
}

function getLinkAttribute(linkDatum, onNormal, onHighlighted, onTrack) { //}, onSourceHover) {
  //if (linkData.source.hovered) return onSourceHover
  if (linkDatum.tracked) return onTrack
  else if (linkDatum.hovered) return onHighlighted
  else return onNormal
}

// connections between modules are faint unless an end node is hovered (focus 'out' / 'in')
function dependencyLinkColor(d) {
  return d.focus == 'out' ? linkColorDependencyOut : d.focus == 'in' ? linkColorDependencyIn : linkColorDependency
}

function setLinkAttributes(link) {
  link
    .attr('stroke', d => getLinkAttribute(d, d.dependency ? dependencyLinkColor(d) : linkColor, linkColorHighlighted, linkColorTracked))
    .attr('stroke-width', d => getLinkAttribute(d, d.dependency ? linkWidthDependency(d.count) : linkWidth, linkWidthHighlighted, linkWidthTracked))
    .attr('stroke-opacity', d => d.dependency && !(d.focus || d.hovered || d.tracked) ? linkOpacityDependency : null)
    .attr('stroke-dasharray', d => d.dependency ? '6 4' : null)
}

function shortenName(name) {
  if (name.length > nodeTextLengthCap) {
    newName = name.slice(0, nodeTextLengthCap - 3) + "..."
    return newName
  }
  else {
    return name
  }
}

function roundReadable(val, type) {
  if (type == 'string') return val
  if (type == 'int') return val
  if (type == 'float') {
    if (val === 0) return 0;

    let isNegative = val < 0;
    val = Math.abs(val);

    let exponent = Math.floor(Math.log10(val));
    let factor = Math.pow(10, exponent - 1);

    let roundedval = Math.round(val / factor) * factor;

    // Handle floating point precision
    roundedval = parseFloat(roundedval.toPrecision(2));

    return isNegative ? -roundedval : roundedval;
  }
}

// one expansion/collapse at a time; clicks arriving while data loads are queued
var pendingUpdate = Promise.resolve()
function queueUpdate(action) {
  pendingUpdate = pendingUpdate.then(action, action)
  return pendingUpdate
}

function collapseAndUpdate(u) {
  return queueUpdate(() => {
    unshowed = [];
    collapse(u);
    saveOldPositions();
    arrangeTree();
    for (let v of unshowed) {
      nodes[v].x = nodes[u].x;
      nodes[v].y = nodes[u].y;
    }
    update();
  })
}
function collapseAndUpdateandJump(u) {
  return queueUpdate(() => {
    unshowed = [];
    collapse(u);
    saveOldPositions();
    arrangeTree();
    for (let v of unshowed) {
      nodes[v].x = nodes[u].x;
      nodes[v].y = nodes[u].y;
    }
    svg.transition().duration(duration).call(
      zoom.transform,
      d3.zoomIdentity.scale(1).translate(-nodes[u].y, -nodes[u].x)
    );
    update();
  })
}

function expandAndUpdate(u) {
  return queueUpdate(async () => {
    await expand(u);
    saveOldPositions();
    arrangeTree();
    svg.transition().duration(duration).call(
      zoom.transform,
      d3.zoomIdentity.scale(1).translate(-nodes[u].y, -nodes[u].x)
    );
    update();
  })
}

// text width in the node label font, measured on a canvas (no layout) and cached per string
const textWidthCache = new Map()
const textMeasureContext = document.createElement('canvas').getContext('2d')
function getTextWidth(text, fontSize = "12px", fontFamily = uiFont) {
  let width = textWidthCache.get(text)
  if (width === undefined) {
    textMeasureContext.font = fontSize + " " + fontFamily
    width = textMeasureContext.measureText(text).width
    textWidthCache.set(text, width)
  }
  return width
}

async function set_dependency(datum){
  lastSearch.property("value", "[ " + datum.name + " ] computing...")
  lastSearch.node().dispatchEvent(new Event('input'));

  await getDependencyOn(datum.id)
  isSomeObserved = true;
  lastSearch.property("value", "[ " + datum.name + " ]")
  lastSearch.node().dispatchEvent(new Event('input'));
}
