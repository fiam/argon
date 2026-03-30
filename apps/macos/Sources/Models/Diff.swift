import Foundation

enum DiffLineKind: String, Codable {
  case context
  case added
  case removed
}

enum DiffViewMode: String, CaseIterable {
  case unified
  case sideBySide

  var label: String {
    switch self {
    case .unified: "Unified"
    case .sideBySide: "Side by Side"
    }
  }

  var icon: String {
    switch self {
    case .unified: "text.alignleft"
    case .sideBySide: "rectangle.split.2x1"
    }
  }
}

// MARK: - Styled Span

struct StyledSpan: Codable, Sendable {
  let text: String
  let fg: String?
  let bold: Bool
  let italic: Bool
  let changed: Bool

  enum CodingKeys: String, CodingKey {
    case text, fg, bold, italic, changed
  }

  init(
    text: String, fg: String? = nil, bold: Bool = false, italic: Bool = false,
    changed: Bool = false
  ) {
    self.text = text
    self.fg = fg
    self.bold = bold
    self.italic = italic
    self.changed = changed
  }
}

// MARK: - Diff Line

struct DiffLine: Identifiable {
  let id = UUID()
  let kind: DiffLineKind
  let spans: [StyledSpan]
  let oldLine: UInt32?
  let newLine: UInt32?

  /// Backward-compatible plain-text content derived from spans.
  var content: String {
    spans.map(\.text).joined()
  }

  /// Legacy initializer for plain-text lines (used by DiffParser.parse fallback).
  init(kind: DiffLineKind, content: String, oldLine: UInt32?, newLine: UInt32?) {
    self.kind = kind
    self.spans = [StyledSpan(text: content)]
    self.oldLine = oldLine
    self.newLine = newLine
  }

  /// Span-based initializer for syntax-highlighted lines.
  init(kind: DiffLineKind, spans: [StyledSpan], oldLine: UInt32?, newLine: UInt32?) {
    self.kind = kind
    self.spans = spans
    self.oldLine = oldLine
    self.newLine = newLine
  }
}

// MARK: - Side-by-Side Pair

struct SideBySidePair: Identifiable {
  let id = UUID()
  let left: DiffLine?
  let right: DiffLine?
}

// MARK: - Diff Hunk

struct DiffHunk: Identifiable {
  let id = UUID()
  let header: String
  let oldStart: UInt32
  let newStart: UInt32
  let lines: [DiffLine]
}

// MARK: - File Diff

struct FileDiff: Identifiable, Hashable {
  /// Stable identity derived from file path so animations work across refreshes.
  let id: String
  let oldPath: String
  let newPath: String
  let hunks: [DiffHunk]
  let sideBySide: [SideBySidePair]
  let addedCount: Int
  let removedCount: Int
  /// Incremented each time the file content changes, so SwiftUI re-renders.
  let lineCount: Int

  init(
    oldPath: String, newPath: String, hunks: [DiffHunk],
    sideBySide: [SideBySidePair] = [],
    addedCount: Int? = nil, removedCount: Int? = nil
  ) {
    self.id = newPath
    self.oldPath = oldPath
    self.newPath = newPath
    self.hunks = hunks
    self.sideBySide = sideBySide
    self.lineCount = hunks.reduce(0) { $0 + $1.lines.count }
    // Use explicit counts if provided, otherwise derive from lines.
    self.addedCount =
      addedCount ?? hunks.flatMap(\.lines).filter { $0.kind == .added }.count
    self.removedCount =
      removedCount ?? hunks.flatMap(\.lines).filter { $0.kind == .removed }.count
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
