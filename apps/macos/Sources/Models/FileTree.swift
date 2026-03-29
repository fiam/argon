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

// MARK: - Glob Filtering

/// Filter files using a glob-like pattern.
/// Supports: * (any chars in segment), ** (any path segments), ? (single char)
func filterFiles(_ files: [FileDiff], pattern: String) -> [FileDiff] {
  let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return files }

  // Convert glob to regex
  let regex = globToRegex(trimmed)

  return files.filter { file in
    file.displayPath.range(of: regex, options: .regularExpression, range: nil, locale: nil) != nil
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
        // ** matches any path segments
        result += ".*"
        i = glob.index(after: next)
        // Skip trailing /
        if i < glob.endIndex && glob[i] == "/" {
          i = glob.index(after: i)
        }
        continue
      } else {
        // * matches anything except /
        result += "[^/]*"
      }
    case "?":
      result += "[^/]"
    case ".":
      result += "\\."
    case "/":
      result += "/"
    default:
      // Case-insensitive matching for letters
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
