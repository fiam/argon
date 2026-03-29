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
  let id = UUID()
  let oldPath: String
  let newPath: String
  let hunks: [DiffHunk]

  var displayPath: String { newPath }

  static func == (lhs: FileDiff, rhs: FileDiff) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
