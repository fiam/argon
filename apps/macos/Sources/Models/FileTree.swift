import Foundation

/// A node in the file tree — either a directory (with children) or a file.
@Observable
final class FileTreeNode: Identifiable {
  let id: String
  let name: String
  let isDirectory: Bool
  var children: [FileTreeNode]
  var file: FileDiff?
  var isExpanded: Bool = true

  init(
    name: String, path: String, isDirectory: Bool, children: [FileTreeNode] = [],
    file: FileDiff? = nil
  ) {
    self.id = path
    self.name = name
    self.isDirectory = isDirectory
    self.children = children
    self.file = file
  }

  /// Total added lines in this subtree.
  var addedCount: Int {
    if let file { return file.addedCount }
    return children.reduce(0) { $0 + $1.addedCount }
  }

  /// Total removed lines in this subtree.
  var removedCount: Int {
    if let file { return file.removedCount }
    return children.reduce(0) { $0 + $1.removedCount }
  }

  /// Number of files in this subtree.
  var fileCount: Int {
    if !isDirectory { return 1 }
    return children.reduce(0) { $0 + $1.fileCount }
  }
}

/// Build a file tree from a flat list of FileDiff.
func buildFileTree(from files: [FileDiff]) -> [FileTreeNode] {
  var root: [String: FileTreeNode] = [:]

  for file in files {
    let components = file.displayPath.split(separator: "/").map(String.init)
    insertIntoTree(root: &root, components: components, pathPrefix: "", file: file)
  }

  return flattenSingleChildDirs(sortNodes(Array(root.values)))
}

private func insertIntoTree(
  root: inout [String: FileTreeNode], components: [String], pathPrefix: String, file: FileDiff
) {
  guard !components.isEmpty else { return }

  if components.count == 1 {
    let name = components[0]
    let node = FileTreeNode(
      name: name, path: file.displayPath, isDirectory: false, file: file)
    root[name] = node
    return
  }

  let dirName = components[0]
  let dirPath = pathPrefix.isEmpty ? dirName : "\(pathPrefix)/\(dirName)"

  if root[dirName] == nil {
    root[dirName] = FileTreeNode(
      name: dirName, path: dirPath, isDirectory: true)
  }

  if let dirNode = root[dirName] {
    var childMap: [String: FileTreeNode] = [:]
    for child in dirNode.children {
      childMap[child.name] = child
    }
    insertIntoTree(
      root: &childMap, components: Array(components.dropFirst()), pathPrefix: dirPath, file: file)
    dirNode.children = sortNodes(Array(childMap.values))
  }
}

private func sortNodes(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
  nodes.sorted { a, b in
    // Directories first, then alphabetical
    if a.isDirectory != b.isDirectory {
      return a.isDirectory
    }
    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
  }
}

/// Collapse single-child directory chains: `src/` → `lib/` → `foo.rs` becomes `src/lib/` → `foo.rs`
private func flattenSingleChildDirs(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
  nodes.map { node in
    var current = node
    while current.isDirectory && current.children.count == 1 && current.children[0].isDirectory {
      let child = current.children[0]
      let merged = FileTreeNode(
        name: "\(current.name)/\(child.name)",
        path: child.id,
        isDirectory: true,
        children: child.children
      )
      merged.isExpanded = current.isExpanded
      current = merged
    }
    current.children = flattenSingleChildDirs(current.children)
    return current
  }
}

// MARK: - File Filtering

enum FilterMode {
  case fuzzy
  case regex
}

/// Detect filter mode and filter files accordingly.
/// Prefix with `/` for regex mode, otherwise fuzzy match.
func filterFiles(_ files: [FileDiff], pattern: String) -> [FileDiff] {
  let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return files }

  if trimmed.hasPrefix("/") {
    let regexPattern = String(trimmed.dropFirst())
    guard !regexPattern.isEmpty else { return files }
    return filterByRegex(files, pattern: regexPattern)
  }

  return filterByFuzzy(files, query: trimmed)
}

/// Fuzzy match: each character in the query must appear in order in the path.
/// Matches across path separators. Case-insensitive.
func fuzzyMatch(_ path: String, query: String) -> (matches: Bool, score: Int) {
  let pathLower = path.lowercased()
  let queryLower = query.lowercased()

  var pathIndex = pathLower.startIndex
  var queryIndex = queryLower.startIndex
  var score = 0
  var prevMatched = false
  var prevWasSeparator = true  // start counts as separator

  while pathIndex < pathLower.endIndex && queryIndex < queryLower.endIndex {
    let pc = pathLower[pathIndex]
    let qc = queryLower[queryIndex]

    if pc == qc {
      // Bonus for consecutive matches
      if prevMatched { score += 5 }
      // Bonus for matching after separator (path segment start)
      if prevWasSeparator { score += 10 }
      // Bonus for matching at start of a "word" (after . or _ or -)
      if pathIndex > pathLower.startIndex {
        let prev = pathLower[pathLower.index(before: pathIndex)]
        if prev == "." || prev == "_" || prev == "-" { score += 8 }
      }
      score += 1
      queryIndex = queryLower.index(after: queryIndex)
      prevMatched = true
    } else {
      prevMatched = false
    }

    prevWasSeparator = pc == "/"
    pathIndex = pathLower.index(after: pathIndex)
  }

  let matched = queryIndex == queryLower.endIndex
  // Prefer shorter paths (less noise)
  if matched {
    score -= path.count / 4
  }
  return (matched, score)
}

private func filterByFuzzy(_ files: [FileDiff], query: String) -> [FileDiff] {
  var scored: [(file: FileDiff, score: Int)] = []
  for file in files {
    let (matches, score) = fuzzyMatch(file.displayPath, query: query)
    if matches {
      scored.append((file, score))
    }
  }
  // Sort by score descending (best matches first)
  scored.sort { $0.score > $1.score }
  return scored.map(\.file)
}

private func filterByRegex(_ files: [FileDiff], pattern: String) -> [FileDiff] {
  files.filter { file in
    file.displayPath.range(
      of: pattern, options: [.regularExpression, .caseInsensitive]
    ) != nil
  }
}
