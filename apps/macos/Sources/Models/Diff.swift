import Foundation

enum DiffLineKind {
  case context
  case added
  case removed
}

struct DiffLine: Identifiable {
  let id = UUID()
  let kind: DiffLineKind
  let content: String
  let oldLine: UInt32?
  let newLine: UInt32?
}

struct DiffHunk: Identifiable {
  let id = UUID()
  let header: String
  let oldStart: UInt32
  let newStart: UInt32
  let lines: [DiffLine]
}

struct FileDiff: Identifiable, Hashable {
  /// Stable identity derived from file path so animations work across refreshes.
  let id: String
  let oldPath: String
  let newPath: String
  let hunks: [DiffHunk]
  /// Incremented each time the file content changes, so SwiftUI re-renders.
  let lineCount: Int

  init(oldPath: String, newPath: String, hunks: [DiffHunk]) {
    self.id = newPath
    self.oldPath = oldPath
    self.newPath = newPath
    self.hunks = hunks
    self.lineCount = hunks.reduce(0) { $0 + $1.lines.count }
  }

  var displayPath: String { newPath }

  static func == (lhs: FileDiff, rhs: FileDiff) -> Bool {
    lhs.id == rhs.id && lhs.lineCount == rhs.lineCount
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(lineCount)
  }
}
