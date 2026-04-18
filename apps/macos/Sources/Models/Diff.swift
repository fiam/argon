import Foundation

enum DiffLineKind: String, Codable {
  case context
  case added
  case removed
}

enum DiffSplitSide: String, Equatable {
  case left
  case right
}

struct DiffAnchor: Hashable, Codable, Sendable, Identifiable {
  let id: String

  static func file(_ fileID: String) -> Self {
    Self(id: "file:\(fileID)")
  }

  static func hunk(fileID: String, ordinal: Int, oldStart: UInt32, newStart: UInt32) -> Self {
    Self(id: "hunk:\(fileID):\(ordinal):\(oldStart):\(newStart)")
  }

  static func line(
    fileID: String, kind: DiffLineKind, oldLine: UInt32?, newLine: UInt32?
  ) -> Self {
    Self(
      id: "line:\(fileID):\(kind.rawValue):\(oldLine ?? 0):\(newLine ?? 0)"
    )
  }

  static func sideBySidePair(fileID: String, ordinal: Int) -> Self {
    Self(id: "pair:\(fileID):\(ordinal)")
  }

  static func omittedContext(fileID: String, ordinal: Int) -> Self {
    Self(id: "omitted-context:\(fileID):\(ordinal)")
  }

  static func thread(_ threadID: UUID) -> Self {
    Self(id: "thread:\(threadID.uuidString)")
  }

  static func draft(_ draftID: UUID) -> Self {
    Self(id: "draft:\(draftID.uuidString)")
  }

  static func commentEditor(forLineID lineID: String) -> Self {
    Self(id: "comment-editor:\(lineID)")
  }

  static let orphanedThreads = Self(id: "orphaned-threads")
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

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    text = try container.decode(String.self, forKey: .text)
    fg = try container.decodeIfPresent(String.self, forKey: .fg)
    bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
    italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
    changed = try container.decodeIfPresent(Bool.self, forKey: .changed) ?? false
  }
}

// MARK: - Diff Line

struct DiffLine: Identifiable {
  let anchor: DiffAnchor
  let kind: DiffLineKind
  let spans: [StyledSpan]
  let oldLine: UInt32?
  let newLine: UInt32?

  var id: String {
    anchor.id
  }

  var preferredSplitSide: DiffSplitSide? {
    switch (oldLine, newLine) {
    case (.some, nil):
      .left
    case (nil, .some):
      .right
    default:
      nil
    }
  }

  /// Plain-text content derived from spans.
  var content: String {
    spans.map(\.text).joined()
  }

  /// Plain-text initializer used by raw diff parsing.
  init(
    anchor: DiffAnchor = DiffAnchor(id: UUID().uuidString),
    kind: DiffLineKind,
    content: String,
    oldLine: UInt32?,
    newLine: UInt32?
  ) {
    self.anchor = anchor
    self.kind = kind
    self.spans = [StyledSpan(text: content)]
    self.oldLine = oldLine
    self.newLine = newLine
  }

  /// Span-based initializer for syntax-highlighted lines.
  init(
    anchor: DiffAnchor = DiffAnchor(id: UUID().uuidString),
    kind: DiffLineKind,
    spans: [StyledSpan],
    oldLine: UInt32?,
    newLine: UInt32?
  ) {
    self.anchor = anchor
    self.kind = kind
    self.spans = spans
    self.oldLine = oldLine
    self.newLine = newLine
  }
}

extension CommentAnchor {
  var preferredSplitSide: DiffSplitSide? {
    switch (lineOld, lineNew) {
    case (.some, nil):
      .left
    case (nil, .some):
      .right
    default:
      nil
    }
  }
}

// MARK: - Side-by-Side Pair

struct SideBySidePair: Identifiable {
  let anchor: DiffAnchor
  let left: DiffLine?
  let right: DiffLine?

  var id: String {
    anchor.id
  }

  init(
    anchor: DiffAnchor = DiffAnchor(id: UUID().uuidString), left: DiffLine?, right: DiffLine?
  ) {
    self.anchor = anchor
    self.left = left
    self.right = right
  }

  var isUnchangedPair: Bool {
    guard let left, let right else { return false }
    return left.anchor == right.anchor
  }

  func line(for side: DiffSplitSide) -> DiffLine? {
    switch side {
    case .left:
      left
    case .right:
      right
    }
  }

  func visualKind(for side: DiffSplitSide) -> DiffLineKind? {
    if let line = line(for: side) {
      return line.kind
    }

    switch side {
    case .left:
      return right?.kind
    case .right:
      return left?.kind
    }
  }
}

// MARK: - Diff Hunk

struct DiffHunk: Identifiable {
  let anchor: DiffAnchor
  let header: String
  let oldStart: UInt32
  let oldLineCount: UInt32
  let newStart: UInt32
  let newLineCount: UInt32
  let lines: [DiffLine]

  var id: String {
    anchor.id
  }

  init(
    anchor: DiffAnchor = DiffAnchor(id: UUID().uuidString),
    header: String,
    oldStart: UInt32,
    oldLineCount: UInt32 = 0,
    newStart: UInt32,
    newLineCount: UInt32 = 0,
    lines: [DiffLine]
  ) {
    self.anchor = anchor
    self.header = header
    self.oldStart = oldStart
    self.oldLineCount = oldLineCount
    self.newStart = newStart
    self.newLineCount = newLineCount
    self.lines = lines
  }
}

enum DiffContextSourceSide: String, Sendable {
  case old
  case new
}

struct DiffContextSource: Sendable {
  let side: DiffContextSourceSide
  let lines: [String]
}

struct DiffContextExpansion: Equatable, Sendable {
  var revealFromTop: Int = 0
  var revealFromBottom: Int = 0
}

enum DiffContextExpandDirection {
  case up
  case down
  case all
}

struct DiffOmittedContextBlock: Identifiable {
  let anchor: DiffAnchor
  let fileID: String
  let filePath: String
  let totalLineCount: Int
  let hiddenLineCount: Int

  var id: String {
    anchor.id
  }
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

  var anchor: DiffAnchor {
    DiffAnchor.file(id)
  }

  init(
    oldPath: String, newPath: String, hunks: [DiffHunk],
    sideBySide: [SideBySidePair] = [],
    addedCount: Int? = nil, removedCount: Int? = nil
  ) {
    self.id = newPath
    self.oldPath = oldPath
    self.newPath = newPath
    self.hunks = Self.stabilizeHunks(hunks, fileID: newPath)
    self.sideBySide = Self.stabilizeSideBySide(sideBySide, fileID: newPath)
    self.lineCount = self.hunks.reduce(0) { $0 + $1.lines.count }
    // Use explicit counts if provided, otherwise derive from lines.
    self.addedCount =
      addedCount ?? self.hunks.flatMap(\.lines).filter { $0.kind == .added }.count
    self.removedCount =
      removedCount ?? self.hunks.flatMap(\.lines).filter { $0.kind == .removed }.count
  }

  var displayPath: String { newPath }

  var preferredOpenPath: String? {
    if newPath != "/dev/null" {
      return newPath
    }
    if oldPath != "/dev/null" {
      return oldPath
    }
    return nil
  }

  static func == (lhs: FileDiff, rhs: FileDiff) -> Bool {
    lhs.id == rhs.id && lhs.lineCount == rhs.lineCount
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(lineCount)
  }

  private static func stabilizeHunks(_ hunks: [DiffHunk], fileID: String) -> [DiffHunk] {
    hunks.enumerated().map { index, hunk in
      DiffHunk(
        anchor: .hunk(
          fileID: fileID,
          ordinal: index,
          oldStart: hunk.oldStart,
          newStart: hunk.newStart
        ),
        header: hunk.header,
        oldStart: hunk.oldStart,
        oldLineCount: hunk.oldLineCount,
        newStart: hunk.newStart,
        newLineCount: hunk.newLineCount,
        lines: hunk.lines.map { stabilizeLine($0, fileID: fileID) }
      )
    }
  }

  private static func stabilizeSideBySide(
    _ sideBySide: [SideBySidePair], fileID: String
  ) -> [SideBySidePair] {
    sideBySide.enumerated().map { index, pair in
      SideBySidePair(
        anchor: .sideBySidePair(fileID: fileID, ordinal: index),
        left: pair.left.map { stabilizeLine($0, fileID: fileID) },
        right: pair.right.map { stabilizeLine($0, fileID: fileID) }
      )
    }
  }

  private static func stabilizeLine(_ line: DiffLine, fileID: String) -> DiffLine {
    DiffLine(
      anchor: .line(
        fileID: fileID,
        kind: line.kind,
        oldLine: line.oldLine,
        newLine: line.newLine
      ),
      kind: line.kind,
      spans: line.spans,
      oldLine: line.oldLine,
      newLine: line.newLine
    )
  }
}
