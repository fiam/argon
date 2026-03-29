import Foundation
import SwiftUI

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

/// The auto-detected filter mode.
enum FilterMode: String {
  case fuzzy
  case glob
  case regex

  var label: String {
    rawValue
  }

  var color: SwiftUI.Color {
    switch self {
    case .fuzzy: .blue
    case .glob: .orange
    case .regex: .purple
    }
  }

  var help: String {
    switch self {
    case .fuzzy:
      """
      Fuzzy matching
      Characters match in order across path segments.
      Case-insensitive. Ranked by relevance.

      Examples: main, uh (matches utils/helper), .toml

      Switch modes:
      · Use * or ? or ** for glob mode
      · Prefix with / for regex mode
      """
    case .glob:
      """
      Glob matching (shell-style)
      * matches any chars in a segment
      ** matches across path segments
      ? matches a single character

      Examples: *.rs, src/**, *test*

      Switch modes:
      · Remove wildcards for fuzzy mode
      · Prefix with / for regex mode
      """
    case .regex:
      """
      Regular expression
      Case-sensitive by default.
      Append /i for case-insensitive.

      Examples: /\\.rs$, /(main|lib), /README/i

      Switch modes:
      · Remove leading / for fuzzy mode
      """
    }
  }
}

/// Detect the filter mode from the pattern string.
func detectFilterMode(_ pattern: String) -> FilterMode {
  let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.hasPrefix("/") { return .regex }
  if trimmed.contains("*") || trimmed.contains("?") { return .glob }
  return .fuzzy
}

/// Filter files using the auto-detected mode.
func filterFiles(_ files: [FileDiff], pattern: String) -> [FileDiff] {
  let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return files }

  switch detectFilterMode(trimmed) {
  case .regex:
    return filterByRegex(files, rawPattern: trimmed)
  case .glob:
    return filterByGlob(files, pattern: trimmed)
  case .fuzzy:
    return filterByFuzzy(files, query: trimmed)
  }
}

// MARK: - Fuzzy

func fuzzyMatch(_ path: String, query: String) -> (matches: Bool, score: Int) {
  let pathLower = path.lowercased()
  let queryLower = query.lowercased()

  var pathIndex = pathLower.startIndex
  var queryIndex = queryLower.startIndex
  var score = 0
  var prevMatched = false
  var prevWasSeparator = true

  while pathIndex < pathLower.endIndex && queryIndex < queryLower.endIndex {
    let pc = pathLower[pathIndex]
    let qc = queryLower[queryIndex]

    if pc == qc {
      if prevMatched { score += 5 }
      if prevWasSeparator { score += 10 }
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
  if matched { score -= path.count / 4 }
  return (matched, score)
}

private func filterByFuzzy(_ files: [FileDiff], query: String) -> [FileDiff] {
  var scored: [(file: FileDiff, score: Int)] = []
  for file in files {
    let (matches, score) = fuzzyMatch(file.displayPath, query: query)
    if matches { scored.append((file, score)) }
  }
  scored.sort { $0.score > $1.score }
  return scored.map(\.file)
}

// MARK: - Glob

private func filterByGlob(_ files: [FileDiff], pattern: String) -> [FileDiff] {
  let regex = globToRegex(pattern)
  return files.filter { file in
    file.displayPath.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
  }
}

private func globToRegex(_ glob: String) -> String {
  var result = "^"
  var i = glob.startIndex

  while i < glob.endIndex {
    let c = glob[i]
    switch c {
    case "*":
      let next = glob.index(after: i)
      if next < glob.endIndex && glob[next] == "*" {
        result += ".*"
        i = glob.index(after: next)
        if i < glob.endIndex && glob[i] == "/" { i = glob.index(after: i) }
        continue
      } else {
        result += "[^/]*"
      }
    case "?": result += "[^/]"
    case ".": result += "\\."
    case "/": result += "/"
    default:
      if c.isLetter {
        result += "[\(c.lowercased())\(c.uppercased())]"
      } else {
        result += String(c)
      }
    }
    i = glob.index(after: i)
  }

  result += "$"
  return result
}

// MARK: - Regex

private func filterByRegex(_ files: [FileDiff], rawPattern: String) -> [FileDiff] {
  var pattern = String(rawPattern.dropFirst())
  var options: String.CompareOptions = [.regularExpression]

  // /pattern/i for case-insensitive
  if pattern.hasSuffix("/i") {
    pattern = String(pattern.dropLast(2))
    options.insert(.caseInsensitive)
  }

  guard !pattern.isEmpty else { return files }

  return files.filter { file in
    file.displayPath.range(of: pattern, options: options) != nil
  }
}
