// fill the window; inside the 1000x600 iframe of the agda-unimath docs this is the iframe size
const width = window.innerWidth || 1000
const height = window.innerHeight || 600

const startNodeColor = '#DF2E38'

// constants for helpToolIcon and helpToolBar
const helpToolIconBoundaryDistance = 34
const iconCircleSize = 30
const iconSpacing = 42 // vertical distance of the icons at the top right

// panels (options, scoreboard, search)
const uiFont = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif'
const panelBorderColor = '#d8dee4'
const panelRadius = 6
const panelMargin = 6

const barWidths = 250;
const barHeights = 400;
const barPaddings = 15;
const barRadii = 5;

const helpToolBarPaddingX = 20
const helpToolBarLineHeight = 20
const helpToolBarPaddingY = 30

const legendToolBarWidth = 250
const colorLegendToolBarWidth = 250;
const spaceGap = 3
const startingCaptionFontSize = 10
const wheelScrollSpeed = 30;
const wheelScrollSpeedFast = 120;

const collapseAllButtonWidth = 100;
const collapseAllButtonHeight = 34;

const scoreboardPadding = {left:5, right:5, top:0, bottom:0 }
const scoreboardNumberOfEntries = 5;
const scoreboardLineHeight = 15;
const scoreboardTextHeightRatio = 0.75
const outlineRadius = 3;
const searchbarRadius = 5;
const dividerThickness = 1;

const searchbarWidth = 200;
const searchbarHeight = 100;

// constants for NODES
const nodeRadius = 7
const nodeSize = 2 * nodeRadius
const nodeStrokeWidth = 3;
const nodeCircleColor = '#4682b4';
const nodeTextLengthCap = 34
const nameLengthLimit = 80
const namesOfEntriesXOffset = 10

const nodeLabels = [
  ':sort', 
  ':axiom', 
  ':primitive', 
  ':function', 
  ':record', 
  'constructor', 
  ':data', 
  ':external-module', 
  ':external-library',
]

const colorPalette = {
  ':sort': '#1b9e77',
  ':axiom': '#e6ab02',
  ':primitive': '#a6761d',
  ':function': '#7570b3',
  ':record': '#a3a3a3',
  ':constructor': '#d95f02',
  ':data': '#66a61e',
  ':external-module': '#e7298a',
  ':external-library': '#d62728',
  // Lean
  ':theorem': '#1f78b4',
  ':recursor': '#8c564b',
  ':abstract': '#17becf',
  ':quot-info': '#bcbd22',
  ':module': '#e7298a',
  ':namespace': '#f4a6cf',
  ':library': '#d62728',
};
const colorUnknownLabel = '#000000'


const nodePropertiesBasic = {
  name: 'name',
  label: 'label',
  in_degree: 'indegree',
  out_degree: 'outdegree',
}

const nodePropertiesBasicType = { 
  name: 'string',
  label: 'string',
  in_degree: 'int',
  out_degree: 'int',

}

const nodePropertiesAdvanced = {
  betweenness: 'betweenness',
  current_flow_betweenness: 'current flow betweenness',
  n_cycles: 'n-cycles',
  eigen_centrality: 'eigen-centrality',
  pagerank: 'pagerank'
}

const nodePropertiesAdvancedType = {
  betweenness: 'float',
  current_flow_betweenness: 'float',
  n_cycles: 'float',
  eigen_centrality: 'float',
  pagerank: 'float'
}

// constants for LINKS
const linkColor = '#d3d9e0'
const linkColorHighlighted = '#ADB446'
const linkColorTracked = '#B44655'
const linkColorSourceHovered = '#708090'

const linkWidth = '2px'
// module view: lifted module dependency links, wider when they stand for more module pairs
const linkColorDependency = '#8fb3d9'
const linkColorDependencyOut = '#2f6fb5' // of the hovered node: modules it uses
const linkColorDependencyIn = '#d9822b'  // of the hovered node: modules using it
const linkOpacityDependency = 0.15
const linkWidthDependency = count => (1 + Math.log10(count)).toFixed(1) + 'px'
const linkWidthHighlighted = '5px'
const linkWidthTracked = linkWidthHighlighted
const linkWidthSourceHovered = linkWidthHighlighted

// constants for TOOLTIPS
const timeHoveredToTooltip = 1000 // milisecond for which a user must hover over the node to display the node's tooltip

const duration = 550 // duration of expansion of tooltip

const numbersRegexp = new RegExp(/\d+(\.\d+)?/, 'g')
// finds all numbers matching the expression and transforms them to numbers
const getFloatsFromString = string =>
  string.match(numbersRegexp).map(parseFloat)

// constants for POSITION
const minimumGapInLevel = 10
const gapBetweenLevels = 220
