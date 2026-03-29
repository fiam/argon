import Foundation

enum DiffParser {

  // MARK: - Highlighted JSON Parsing

  /// Parses the highlighted JSON output from `argon diff --json`.
  static func parseHighlighted(_ json: String) -> [FileDiff] {
    guard let data = json.data(using: .utf8) else { return [] }
    do {
      let response = try JSONDecoder().decode(HighlightedDiffResponse.self, from: data)
      return response.files.map { file in
        let hunks = file.unifiedHunks.map { hunk in
          DiffHunk(
            header: hunk.header,
            oldStart: parseOldStart(hunk.header),
            newStart: parseNewStart(hunk.header),
            lines: hunk.lines.map { line in
              DiffLine(
                kind: line.decodedKind,
                spans: line.spans,
                oldLine: line.oldLine,
                newLine: line.newLine
              )
            }
          )
        }
        let sideBySide = file.sideBySide.map { pair in
          SideBySidePair(
            left: pair.left.map { line in
              DiffLine(
                kind: line.decodedKind,
                spans: line.spans,
                oldLine: line.oldLine,
                newLine: line.newLine
              )
            },
            right: pair.right.map { line in
              DiffLine(
                kind: line.decodedKind,
                spans: line.spans,
                oldLine: line.oldLine,
                newLine: line.newLine
              )
            }
          )
        }
        return FileDiff(
          oldPath: file.oldPath,
          newPath: file.newPath,
          hunks: hunks,
          sideBySide: sideBySide,
          addedCount: file.addedCount,
          removedCount: file.removedCount
        )
      }
    } catch {
      return []
    }
  }

  // MARK: - Highlighted JSON Codable Types

  private struct HighlightedDiffResponse: Codable {
    let baseRef: String
    let headRef: String
    let files: [HighlightedFile]

    enum CodingKeys: String, CodingKey {
      case baseRef = "base_ref"
      case headRef = "head_ref"
      case files
    }
  }

  private struct HighlightedFile: Codable {
    let oldPath: String
    let newPath: String
    let addedCount: Int
    let removedCount: Int
    let unifiedHunks: [HighlightedHunk]
    let sideBySide: [HighlightedSideBySidePair]

    enum CodingKeys: String, CodingKey {
      case oldPath = "old_path"
      case newPath = "new_path"
      case addedCount = "added_count"
      case removedCount = "removed_count"
      case unifiedHunks = "unified_hunks"
      case sideBySide = "side_by_side"
    }
  }

  private struct HighlightedHunk: Codable {
    let header: String
    let lines: [HighlightedLine]
  }

  private struct HighlightedSideBySidePair: Codable {
    let left: HighlightedLine?
    let right: HighlightedLine?
  }

  private struct HighlightedLine: Codable {
    let kind: String
    let oldLine: UInt32?
    let newLine: UInt32?
    let spans: [StyledSpan]

    enum CodingKeys: String, CodingKey {
      case kind
      case oldLine = "old_line"
      case newLine = "new_line"
      case spans
    }

    var decodedKind: DiffLineKind {
      switch kind {
      case "added": .added
      case "removed": .removed
      default: .context
      }
    }
  }

  private static func parseOldStart(_ header: String) -> UInt32 {
    guard let parsed = parseHunkHeader(header) else { return 0 }
    return parsed.oldStart
  }

  private static func parseNewStart(_ header: String) -> UInt32 {
    guard let parsed = parseHunkHeader(header) else { return 0 }
    return parsed.newStart
  }

  // MARK: - Legacy Raw Diff Parsing (fallback)

  static func parse(_ raw: String) -> [FileDiff] {
    var files: [FileDiff] = []
    var currentOldPath: String?
    var currentNewPath: String?
    var currentHunks: [DiffHunk] = []
    var currentLines: [DiffLine] = []
    var currentHeader = ""
    var oldStart: UInt32 = 0
    var newStart: UInt32 = 0
    var oldCursor: UInt32 = 0
    var newCursor: UInt32 = 0

    func finalizeHunk() {
      if !currentLines.isEmpty {
        currentHunks.append(
          DiffHunk(
            header: currentHeader,
            oldStart: oldStart,
            newStart: newStart,
            lines: currentLines
          ))
        currentLines = []
      }
    }

    func finalizeFile() {
      finalizeHunk()
      if let oldPath = currentOldPath, let newPath = currentNewPath {
        files.append(
          FileDiff(
            oldPath: oldPath,
            newPath: newPath,
            hunks: currentHunks
          ))
      }
      currentOldPath = nil
      currentNewPath = nil
      currentHunks = []
    }

    for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if line.hasPrefix("diff --git ") {
        finalizeFile()
        let (oldP, newP) = parseDiffHeader(line)
        currentOldPath = oldP
        currentNewPath = newP
        continue
      }

      if line.hasPrefix("@@ ") {
        finalizeHunk()
        if let parsed = parseHunkHeader(line) {
          oldStart = parsed.oldStart
          newStart = parsed.newStart
          oldCursor = parsed.oldStart
          newCursor = parsed.newStart
          currentHeader = line
        }
        continue
      }

      if shouldSkipMetadata(line) { continue }
      if line.hasPrefix("\\") { continue }

      guard let first = line.first else { continue }
      let content = String(line.dropFirst())

      switch first {
      case " ":
        currentLines.append(
          DiffLine(
            kind: .context, content: content,
            oldLine: oldCursor, newLine: newCursor
          ))
        oldCursor += 1
        newCursor += 1
      case "+":
        currentLines.append(
          DiffLine(
            kind: .added, content: content,
            oldLine: nil, newLine: newCursor
          ))
        newCursor += 1
      case "-":
        currentLines.append(
          DiffLine(
            kind: .removed, content: content,
            oldLine: oldCursor, newLine: nil
          ))
        oldCursor += 1
      default:
        break
      }
    }

    finalizeFile()
    return files
  }

  private static func parseDiffHeader(_ line: String) -> (String, String) {
    let stripped = line.dropFirst("diff --git ".count)
    let parts = stripped.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else { return ("", "") }
    let oldPath = stripPrefix(String(parts[0]), prefix: "a/")
    let newPath = stripPrefix(String(parts[1]), prefix: "b/")
    return (oldPath, newPath)
  }

  private static func stripPrefix(_ s: String, prefix: String) -> String {
    s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
  }

  private struct ParsedHunk {
    let oldStart: UInt32
    let newStart: UInt32
  }

  private static func parseHunkHeader(_ line: String) -> ParsedHunk? {
    // @@ -old_start[,old_lines] +new_start[,new_lines] @@
    guard let atRange = line.range(of: "@@ -") else { return nil }
    let rest = line[atRange.upperBound...]
    guard let endRange = rest.range(of: " @@") else { return nil }
    let ranges = rest[rest.startIndex..<endRange.lowerBound]
    let parts = ranges.split(separator: " +")
    guard parts.count == 2 else { return nil }

    let oldPart = parts[0].split(separator: ",")
    let newPart = parts[1].split(separator: ",")

    guard let oldStart = UInt32(oldPart[0]),
      let newStart = UInt32(newPart[0])
    else { return nil }

    return ParsedHunk(oldStart: oldStart, newStart: newStart)
  }

  private static func shouldSkipMetadata(_ line: String) -> Bool {
    let prefixes = [
      "index ", "--- ", "+++ ", "new file mode ", "deleted file mode ",
      "similarity index ", "rename from ", "rename to ", "Binary files ",
    ]
    return prefixes.contains { line.hasPrefix($0) }
  }
}
