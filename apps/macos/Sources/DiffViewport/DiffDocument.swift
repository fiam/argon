import Foundation

enum DiffNavigationAlignment: String, Equatable {
  case top
  case center
}

struct DiffNavigationRequest: Identifiable, Equatable {
  let id: UUID
  let anchor: DiffAnchor
  let fallbackFileID: String?
  let alignment: DiffNavigationAlignment
  let animated: Bool

  init(
    id: UUID = UUID(),
    anchor: DiffAnchor,
    fallbackFileID: String? = nil,
    alignment: DiffNavigationAlignment = .top,
    animated: Bool = false
  ) {
    self.id = id
    self.anchor = anchor
    self.fallbackFileID = fallbackFileID
    self.alignment = alignment
    self.animated = animated
  }
}

enum DiffInlineAttachment: Identifiable {
  case thread(ReviewThread, isOutdated: Bool)
  case draft(DraftComment)

  var id: String {
    switch self {
    case .thread(let thread, _):
      DiffAnchor.thread(thread.id).id
    case .draft(let draft):
      DiffAnchor.draft(draft.id).id
    }
  }
}

enum DiffInlineResolver {
  static func attachmentsByLineID(
    for file: FileDiff,
    session: ReviewSession?,
    pendingDrafts: [DraftComment]
  ) -> [String: [DiffInlineAttachment]] {
    var result: [String: [DiffInlineAttachment]] = [:]
    let lines = renderableLines(for: file)

    let outdatedSet = Set(outdatedThreads(for: file, session: session).map(\.id))

    if let session {
      for thread in session.threads {
        guard let anchor = thread.comments.first?.anchor, anchor.filePath == file.newPath else {
          continue
        }

        let isOutdated = outdatedSet.contains(thread.id)
        if let line = targetLine(for: anchor, in: lines) {
          result[line.id, default: []].append(.thread(thread, isOutdated: isOutdated))
        }
      }
    }

    for draft in pendingDrafts {
      guard draft.anchor.filePath == file.newPath else {
        continue
      }
      if let line = targetLine(for: draft.anchor, in: lines) {
        result[line.id, default: []].append(.draft(draft))
      }
    }

    return result
  }

  static func orphanedThreads(files: [FileDiff], session: ReviewSession?) -> [ReviewThread] {
    guard let session else { return [] }
    let filesInDiff = Set(files.map(\.newPath))
    return session.threads.filter { thread in
      guard let anchor = thread.comments.first?.anchor, let filePath = anchor.filePath else {
        return false
      }
      return !filesInDiff.contains(filePath)
    }
  }

  static func outdatedThreads(for file: FileDiff, session: ReviewSession?) -> [ReviewThread] {
    guard let session else { return [] }
    let removedLines = Set(
      file.hunks.flatMap(\.lines)
        .filter { $0.kind == .removed }
        .compactMap(\.oldLine)
    )

    return session.threads.filter { thread in
      guard let anchor = thread.comments.first?.anchor, anchor.filePath == file.newPath else {
        return false
      }
      if let oldLine = anchor.lineOld, removedLines.contains(oldLine) {
        return true
      }
      return false
    }
  }

  static func attachments(
    for pair: SideBySidePair,
    attachmentsByLineID: [String: [DiffInlineAttachment]]
  ) -> [DiffInlineAttachment] {
    var seen = Set<String>()
    var result: [DiffInlineAttachment] = []

    for line in [pair.left, pair.right].compactMap({ $0 }) {
      for item in attachmentsByLineID[line.id] ?? [] where seen.insert(item.id).inserted {
        result.append(item)
      }
    }

    return result
  }

  private static func renderableLines(for file: FileDiff) -> [DiffLine] {
    var ordered: [DiffLine] = []
    var seen = Set<String>()

    for line in file.hunks.flatMap(\.lines) {
      if seen.insert(line.id).inserted {
        ordered.append(line)
      }
    }

    for pair in file.sideBySide {
      for line in [pair.left, pair.right].compactMap({ $0 }) {
        if seen.insert(line.id).inserted {
          ordered.append(line)
        }
      }
    }

    return ordered
  }

  private static func targetLine(for anchor: CommentAnchor, in lines: [DiffLine]) -> DiffLine? {
    if let lineNew = anchor.lineNew,
      let exactNew = lines.first(where: { $0.newLine == lineNew })
    {
      return exactNew
    }

    if let lineOld = anchor.lineOld,
      let exactOld = lines.first(where: { $0.oldLine == lineOld })
    {
      return exactOld
    }

    if let lineNew = anchor.lineNew {
      return nearestLine(to: lineNew, in: lines, keyPath: \.newLine)
    }

    if let lineOld = anchor.lineOld {
      return nearestLine(to: lineOld, in: lines, keyPath: \.oldLine)
    }

    return lines.first
  }

  private static func nearestLine(
    to target: UInt32,
    in lines: [DiffLine],
    keyPath: KeyPath<DiffLine, UInt32?>
  ) -> DiffLine? {
    let candidates: [(line: DiffLine, distance: Int)] = lines.compactMap { line in
      guard let value = line[keyPath: keyPath] else { return nil }
      return (line: line, distance: abs(Int(value) - Int(target)))
    }

    return candidates.min(by: { $0.distance < $1.distance })?.line
  }
}

enum DiffDocumentRowKind: Hashable {
  case orphanedThread
  case fileHeader
  case hunkHeader
  case unifiedLine
  case sideBySidePair
  case inlineThread(isOutdated: Bool)
  case inlineDraft
  case commentEditor
}

enum DiffDocumentRowPlacement: Equatable {
  case fullWidth
  case split(side: DiffSplitSide)
}

enum DiffDocumentRowPayload {
  case orphanedThread(ReviewThread)
  case fileHeader(FileDiff)
  case hunkHeader(filePath: String, hunk: DiffHunk)
  case unifiedLine(filePath: String, line: DiffLine)
  case sideBySidePair(filePath: String, pair: SideBySidePair)
  case inlineThread(ReviewThread, isOutdated: Bool)
  case inlineDraft(DraftComment)
  case commentEditor(filePath: String, line: DiffLine)
}

struct DiffDocumentRow: Identifiable {
  let anchor: DiffAnchor
  let payload: DiffDocumentRowPayload
  let fileID: String?
  let placement: DiffDocumentRowPlacement
  let additionalAnchors: [DiffAnchor]

  init(
    anchor: DiffAnchor,
    payload: DiffDocumentRowPayload,
    fileID: String?,
    placement: DiffDocumentRowPlacement = .fullWidth,
    additionalAnchors: [DiffAnchor] = []
  ) {
    self.anchor = anchor
    self.payload = payload
    self.fileID = fileID
    self.placement = placement
    self.additionalAnchors = additionalAnchors
  }

  var id: String {
    anchor.id
  }

  var kind: DiffDocumentRowKind {
    switch payload {
    case .orphanedThread:
      .orphanedThread
    case .fileHeader:
      .fileHeader
    case .hunkHeader:
      .hunkHeader
    case .unifiedLine:
      .unifiedLine
    case .sideBySidePair:
      .sideBySidePair
    case .inlineThread(_, let isOutdated):
      .inlineThread(isOutdated: isOutdated)
    case .inlineDraft:
      .inlineDraft
    case .commentEditor:
      .commentEditor
    }
  }
}

struct DiffDocument {
  let rows: [DiffDocumentRow]
  private let rowIndexByAnchor: [DiffAnchor: Int]

  init(rows: [DiffDocumentRow]) {
    self.rows = rows
    var rowIndexByAnchor: [DiffAnchor: Int] = [:]
    for (index, row) in rows.enumerated() {
      rowIndexByAnchor[row.anchor] = index
      for alias in row.additionalAnchors {
        rowIndexByAnchor[alias] = index
      }
    }
    self.rowIndexByAnchor = rowIndexByAnchor
  }

  func contains(anchor: DiffAnchor) -> Bool {
    rowIndexByAnchor[anchor] != nil
  }

  func index(for anchor: DiffAnchor) -> Int? {
    rowIndexByAnchor[anchor]
  }

  func row(for anchor: DiffAnchor) -> DiffDocumentRow? {
    guard let index = index(for: anchor) else { return nil }
    return rows[index]
  }
}

enum DiffDocumentBuilder {
  static func build(
    files: [FileDiff],
    session: ReviewSession?,
    pendingDrafts: [DraftComment],
    diffMode: DiffViewMode,
    activeCommentLineID: String?
  ) -> DiffDocument {
    var rows: [DiffDocumentRow] = []

    for thread in DiffInlineResolver.orphanedThreads(files: files, session: session) {
      rows.append(
        DiffDocumentRow(
          anchor: .thread(thread.id),
          payload: .orphanedThread(thread),
          fileID: thread.comments.first?.anchor.filePath
        )
      )
    }

    for file in files {
      rows.append(
        DiffDocumentRow(anchor: file.anchor, payload: .fileHeader(file), fileID: file.id)
      )

      let attachmentsByLineID = DiffInlineResolver.attachmentsByLineID(
        for: file,
        session: session,
        pendingDrafts: pendingDrafts
      )

      switch diffMode {
      case .unified:
        appendUnifiedRows(
          to: &rows,
          file: file,
          attachmentsByLineID: attachmentsByLineID,
          activeCommentLineID: activeCommentLineID
        )
      case .sideBySide:
        if file.sideBySide.isEmpty {
          appendUnifiedRows(
            to: &rows,
            file: file,
            attachmentsByLineID: attachmentsByLineID,
            activeCommentLineID: activeCommentLineID
          )
        } else {
          for pair in file.sideBySide {
            rows.append(
              DiffDocumentRow(
                anchor: pair.anchor,
                payload: .sideBySidePair(filePath: file.newPath, pair: pair),
                fileID: file.id,
                additionalAnchors: [pair.left?.anchor, pair.right?.anchor].compactMap { $0 }
              )
            )

            if let editorLine = activeEditorLine(
              for: pair,
              activeCommentLineID: activeCommentLineID
            ) {
              rows.append(
                DiffDocumentRow(
                  anchor: .commentEditor(forLineID: editorLine.id),
                  payload: .commentEditor(filePath: file.newPath, line: editorLine),
                  fileID: file.id,
                  placement: placement(for: editorLine)
                )
              )
            }

            rows.append(
              contentsOf: attachmentRows(
                DiffInlineResolver.attachments(for: pair, attachmentsByLineID: attachmentsByLineID),
                fileID: file.id,
                placement: placement(for:)
              )
            )
          }
        }
      }
    }

    return DiffDocument(rows: rows)
  }

  private static func attachmentRows(
    _ items: [DiffInlineAttachment],
    fileID: String,
    placement: @escaping (DiffInlineAttachment) -> DiffDocumentRowPlacement = { _ in .fullWidth }
  ) -> [DiffDocumentRow] {
    items.map { item in
      switch item {
      case .thread(let thread, let isOutdated):
        DiffDocumentRow(
          anchor: .thread(thread.id),
          payload: .inlineThread(thread, isOutdated: isOutdated),
          fileID: fileID,
          placement: placement(item)
        )
      case .draft(let draft):
        DiffDocumentRow(
          anchor: .draft(draft.id),
          payload: .inlineDraft(draft),
          fileID: fileID,
          placement: placement(item)
        )
      }
    }
  }

  private static func appendUnifiedRows(
    to rows: inout [DiffDocumentRow],
    file: FileDiff,
    attachmentsByLineID: [String: [DiffInlineAttachment]],
    activeCommentLineID: String?
  ) {
    for hunk in file.hunks {
      rows.append(
        DiffDocumentRow(
          anchor: hunk.anchor,
          payload: .hunkHeader(filePath: file.newPath, hunk: hunk),
          fileID: file.id
        )
      )

      for line in hunk.lines {
        rows.append(
          DiffDocumentRow(
            anchor: line.anchor,
            payload: .unifiedLine(filePath: file.newPath, line: line),
            fileID: file.id
          )
        )

        if activeCommentLineID == line.id {
          rows.append(
            DiffDocumentRow(
              anchor: .commentEditor(forLineID: line.id),
              payload: .commentEditor(filePath: file.newPath, line: line),
              fileID: file.id
            )
          )
        }

        if let items = attachmentsByLineID[line.id] {
          rows.append(contentsOf: attachmentRows(items, fileID: file.id))
        }
      }
    }
  }

  private static func activeEditorLine(
    for pair: SideBySidePair,
    activeCommentLineID: String?
  ) -> DiffLine? {
    guard let activeCommentLineID else { return nil }
    return [pair.right, pair.left].compactMap { $0 }.first(where: { $0.id == activeCommentLineID })
  }

  private static func placement(for line: DiffLine) -> DiffDocumentRowPlacement {
    line.preferredSplitSide.map { .split(side: $0) } ?? .fullWidth
  }

  private static func placement(for item: DiffInlineAttachment) -> DiffDocumentRowPlacement {
    let side: DiffSplitSide? =
      switch item {
      case .thread(let thread, _):
        thread.comments.first?.anchor.preferredSplitSide
      case .draft(let draft):
        draft.anchor.preferredSplitSide
      }

    return side.map { .split(side: $0) } ?? .fullWidth
  }
}
