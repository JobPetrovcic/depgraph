/-! The web page, built into the executable: (path in the site, contents). -/

namespace DepGraph

def webFiles : Array (String × String) := #[
  ("index.html", include_str ".." / "web" / "index.html"),
  ("visualize.html", include_str ".." / "web" / "visualize.html"),
  ("scripts/helpers.js", include_str ".." / "web" / "scripts" / "helpers.js"),
  ("scripts/constants.js", include_str ".." / "web" / "scripts" / "constants.js"),
  ("scripts/librarySpecificSettings.js", include_str ".." / "web" / "scripts" / "librarySpecificSettings.js"),
  ("scripts/setUpData.js", include_str ".." / "web" / "scripts" / "setUpData.js"),
  ("scripts/setupSvg.js", include_str ".." / "web" / "scripts" / "setupSvg.js"),
  ("scripts/sourceCard.js", include_str ".." / "web" / "scripts" / "sourceCard.js"),
  ("scripts/moduleConnections.js", include_str ".." / "web" / "scripts" / "moduleConnections.js"),
  ("scripts/expansion.js", include_str ".." / "web" / "scripts" / "expansion.js"),
  ("scripts/arrangeTree.js", include_str ".." / "web" / "scripts" / "arrangeTree.js")]

end DepGraph
