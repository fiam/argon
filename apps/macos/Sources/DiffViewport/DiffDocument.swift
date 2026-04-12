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
    filePath: String,
    visibleLines: [DiffLine],
    removedOldLines: Set<UInt32>,
    session: ReviewSession?,
    pendingDrafts: [DraftComment]
  ) -> [String: [DiffInlineAttachment]] {
    var result: [String: [DiffInlineAttachment]] = [:]

    let outdatedSet = Set(
      outdatedThreads(
        filePath: filePath,
        removedOldLines: removedOldLines,
        session: session
      ).map(\.id)
    )

    if let session {
      for thread in session.threads {
        guard let anchor = thread.comments.first?.anchor, anchor.filePath == filePath else {
          continue
        }

        let isOutdated = outdatedSet.contains(thread.id)
        if let line = targetLine(for: anchor, in: visibleLines) {
          result[line.id, default: []].append(.thread(thread, isOutdated: isOutdated))
        }
      }
    }

    for draft in pendingDrafts {
      guard draft.anchor.filePath == filePath else {
        continue
      }
      if let line = targetLine(for: draft.anchor, in: visibleLines) {
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
    outdatedThreads(
      filePath: file.newPath,
      removedOldLines: Set(
        file.hunks.flatMap(\.lines)
          .filter { $0.kind == .removed }
          .compactMap(\.oldLine)
      ),
      session: session
    )
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

  static func renderableLines(for file: FileDiff) -> [DiffLine] {
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

  static func targetLine(for anchor: CommentAnchor, in lines: [DiffLine]) -> DiffLine? {
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

  private static func outdatedThreads(
    filePath: String,
    removedOldLines: Set<UInt32>,
    session: ReviewSession?
  ) -> [ReviewThread] {
    guard let session else { return [] }

    return session.threads.filter { thread in
      guard let anchor = thread.comments.first?.anchor, anchor.filePath == filePath else {
        return false
      }
      guard let oldLine = anchor.lineOld else { return false }
      return removedOldLines.contains(oldLine)
    }
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
  case omittedContext
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
  case omittedContext(DiffOmittedContextBlock)
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
    case .omittedContext:
      .omittedContext
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

private enum DiffProjectedFileItem {
  case omittedContext(DiffOmittedContextBlock)
  case hunkHeader(DiffHunk)
  case line(DiffLine)
}

enum DiffDocumentBuilder {
  static func build(
    files: [FileDiff],
    session: ReviewSession?,
    pendingDrafts: [DraftComment],
    diffMode: DiffViewMode,
    activeCommentLineID: String?,
    contextSources: [String: DiffContextSource],
    contextExpansion: [String: DiffContextExpansion]
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

      let projectedItems = projectedItems(
        for: file,
        contextSource: contextSources[file.id],
        contextExpansion: contextExpansion
      )
      let projectedVisibleLines = projectedItems.compactMap { item in
        if case .line(let line) = item {
          line
        } else {
          nil
        }
      }
      let visibleLines =
        projectedVisibleLines.isEmpty
        ? DiffInlineResolver.renderableLines(for: file)
        : projectedVisibleLines

      let attachmentsByLineID = DiffInlineResolver.attachmentsByLineID(
        filePath: file.newPath,
        visibleLines: visibleLines,
        removedOldLines: Set(
          file.hunks.flatMap(\.lines)
            .filter { $0.kind == .removed }
            .compactMap(\.oldLine)
        ),
        session: session,
        pendingDrafts: pendingDrafts
      )

      switch diffMode {
      case .unified:
        appendUnifiedRows(
          to: &rows,
          file: file,
          projectedItems: projectedItems,
          attachmentsByLineID: attachmentsByLineID,
          activeCommentLineID: activeCommentLineID
        )
      case .sideBySide:
        appendSideBySideRows(
          to: &rows,
          file: file,
          projectedItems: projectedItems,
          attachmentsByLineID: attachmentsByLineID,
          activeCommentLineID: activeCommentLineID
        )
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
    projectedItems: [DiffProjectedFileItem],
    attachmentsByLineID: [String: [DiffInlineAttachment]],
    activeCommentLineID: String?
  ) {
    for item in projectedItems {
      switch item {
      case .omittedContext(let block):
        rows.append(
          DiffDocumentRow(
            anchor: block.anchor,
            payload: .omittedContext(block),
            fileID: file.id
          )
        )
      case .hunkHeader(let hunk):
        rows.append(
          DiffDocumentRow(
            anchor: hunk.anchor,
            payload: .hunkHeader(filePath: file.newPath, hunk: hunk),
            fileID: file.id
          )
        )
      case .line(let line):
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

  private static func appendSideBySideRows(
    to rows: inout [DiffDocumentRow],
    file: FileDiff,
    projectedItems: [DiffProjectedFileItem],
    attachmentsByLineID: [String: [DiffInlineAttachment]],
    activeCommentLineID: String?
  ) {
    if projectedItems.isEmpty && !file.sideBySide.isEmpty {
      for pair in file.sideBySide {
        rows.append(
          DiffDocumentRow(
            anchor: pair.anchor,
            payload: .sideBySidePair(filePath: file.newPath, pair: pair),
            fileID: file.id,
            additionalAnchors: [pair.left?.anchor, pair.right?.anchor].compactMap { $0 }
          )
        )

        if let editorLine = activeEditorLine(for: pair, activeCommentLineID: activeCommentLineID) {
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
      return
    }

    var bufferedLines: [DiffLine] = []
    var pairOrdinal = 0

    func flushBufferedLines() {
      guard !bufferedLines.isEmpty else { return }

      for pair in buildSideBySidePairs(
        from: bufferedLines, fileID: file.id, startOrdinal: pairOrdinal)
      {
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
        pairOrdinal += 1
      }

      bufferedLines.removeAll(keepingCapacity: true)
    }

    for item in projectedItems {
      switch item {
      case .line(let line):
        bufferedLines.append(line)
      case .omittedContext(let block):
        flushBufferedLines()
        rows.append(
          DiffDocumentRow(
            anchor: block.anchor,
            payload: .omittedContext(block),
            fileID: file.id
          )
        )
      case .hunkHeader(let hunk):
        flushBufferedLines()
        rows.append(
          DiffDocumentRow(
            anchor: hunk.anchor,
            payload: .hunkHeader(filePath: file.newPath, hunk: hunk),
            fileID: file.id
          )
        )
      }
    }

    flushBufferedLines()
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

  private static func projectedItems(
    for file: FileDiff,
    contextSource: DiffContextSource?,
    contextExpansion: [String: DiffContextExpansion]
  ) -> [DiffProjectedFileItem] {
    guard let contextSource, !file.hunks.isEmpty else {
      return file.hunks.flatMap { hunk in
        [DiffProjectedFileItem.hunkHeader(hunk)] + hunk.lines.map(DiffProjectedFileItem.line)
      }
    }

    var items: [DiffProjectedFileItem] = []

    for (index, hunk) in file.hunks.enumerated() {
      if index == 0 {
        items.append(
          contentsOf: gapItems(
            file: file,
            gapOrdinal: 0,
            startOldLine: 1,
            startNewLine: 1,
            hiddenLineCount: leadingHiddenLineCount(for: hunk),
            sourceStartLine: 1,
            contextSource: contextSource,
            contextExpansion: contextExpansion
          )
        )
      } else {
        let previous = file.hunks[index - 1]
        let startOldLine = Int(previous.oldStart + previous.oldLineCount)
        let startNewLine = Int(previous.newStart + previous.newLineCount)
        let hiddenLineCount = max(
          0,
          min(
            Int(hunk.oldStart) - startOldLine,
            Int(hunk.newStart) - startNewLine
          )
        )

        items.append(
          contentsOf: gapItems(
            file: file,
            gapOrdinal: index,
            startOldLine: startOldLine,
            startNewLine: startNewLine,
            hiddenLineCount: hiddenLineCount,
            sourceStartLine: contextSource.side == .new ? startNewLine : startOldLine,
            contextSource: contextSource,
            contextExpansion: contextExpansion
          )
        )
      }

      items.append(.hunkHeader(hunk))
      items.append(contentsOf: hunk.lines.map(DiffProjectedFileItem.line))
    }

    if let lastHunk = file.hunks.last {
      let startOldLine = Int(lastHunk.oldStart + lastHunk.oldLineCount)
      let startNewLine = Int(lastHunk.newStart + lastHunk.newLineCount)
      let sourceStartLine = contextSource.side == .new ? startNewLine : startOldLine
      let hiddenLineCount = max(0, contextSource.lines.count - sourceStartLine + 1)

      items.append(
        contentsOf: gapItems(
          file: file,
          gapOrdinal: file.hunks.count,
          startOldLine: startOldLine,
          startNewLine: startNewLine,
          hiddenLineCount: hiddenLineCount,
          sourceStartLine: sourceStartLine,
          contextSource: contextSource,
          contextExpansion: contextExpansion
        )
      )
    }

    return items
  }

  private static func gapItems(
    file: FileDiff,
    gapOrdinal: Int,
    startOldLine: Int,
    startNewLine: Int,
    hiddenLineCount: Int,
    sourceStartLine: Int,
    contextSource: DiffContextSource,
    contextExpansion: [String: DiffContextExpansion]
  ) -> [DiffProjectedFileItem] {
    guard hiddenLineCount > 0, sourceStartLine > 0 else { return [] }

    let anchor = DiffAnchor.omittedContext(fileID: file.id, ordinal: gapOrdinal)
    let expansion = contextExpansion[anchor.id] ?? DiffContextExpansion()
    let topCount = min(expansion.revealFromTop, hiddenLineCount)
    let remainingAfterTop = max(0, hiddenLineCount - topCount)
    let bottomCount = min(expansion.revealFromBottom, remainingAfterTop)
    let remainingHidden = max(0, hiddenLineCount - topCount - bottomCount)

    var items: [DiffProjectedFileItem] = []

    if topCount > 0 {
      items.append(
        contentsOf: makeContextLines(
          fileID: file.id,
          startOldLine: startOldLine,
          startNewLine: startNewLine,
          sourceStartLine: sourceStartLine,
          count: topCount,
          contextSource: contextSource
        ).map(DiffProjectedFileItem.line)
      )
    }

    if remainingHidden > 0 {
      items.append(
        .omittedContext(
          DiffOmittedContextBlock(
            anchor: anchor,
            fileID: file.id,
            filePath: file.newPath,
            totalLineCount: hiddenLineCount,
            hiddenLineCount: remainingHidden
          )
        )
      )
    }

    if bottomCount > 0 {
      let skipped = hiddenLineCount - bottomCount
      items.append(
        contentsOf: makeContextLines(
          fileID: file.id,
          startOldLine: startOldLine + skipped,
          startNewLine: startNewLine + skipped,
          sourceStartLine: sourceStartLine + skipped,
          count: bottomCount,
          contextSource: contextSource
        ).map(DiffProjectedFileItem.line)
      )
    }

    return items
  }

  private static func makeContextLines(
    fileID: String,
    startOldLine: Int,
    startNewLine: Int,
    sourceStartLine: Int,
    count: Int,
    contextSource: DiffContextSource
  ) -> [DiffLine] {
    guard count > 0 else { return [] }
    let sourceIndex = sourceStartLine - 1
    guard sourceIndex >= 0, sourceIndex < contextSource.lines.count else { return [] }

    let endIndex = min(sourceIndex + count, contextSource.lines.count)

    return contextSource.lines[sourceIndex..<endIndex].enumerated().map { offset, content in
      let oldLine = UInt32(startOldLine + offset)
      let newLine = UInt32(startNewLine + offset)
      return DiffLine(
        anchor: .line(
          fileID: fileID,
          kind: .context,
          oldLine: oldLine,
          newLine: newLine
        ),
        kind: .context,
        content: content,
        oldLine: oldLine,
        newLine: newLine
      )
    }
  }

  private static func leadingHiddenLineCount(for hunk: DiffHunk) -> Int {
    let oldGap = hunk.oldStart > 0 ? Int(hunk.oldStart) - 1 : 0
    let newGap = hunk.newStart > 0 ? Int(hunk.newStart) - 1 : 0
    return max(0, min(oldGap, newGap))
  }

  private static func buildSideBySidePairs(
    from lines: [DiffLine],
    fileID: String,
    startOrdinal: Int
  ) -> [SideBySidePair] {
    var pairs: [SideBySidePair] = []
    var lineIndex = 0
    var ordinal = startOrdinal

    while lineIndex < lines.count {
      switch lines[lineIndex].kind {
      case .context:
        let line = lines[lineIndex]
        pairs.append(
          SideBySidePair(
            anchor: .sideBySidePair(fileID: fileID, ordinal: ordinal),
            left: line,
            right: line
          )
        )
        ordinal += 1
        lineIndex += 1
      case .removed:
        var removed: [DiffLine] = []
        while lineIndex < lines.count && lines[lineIndex].kind == .removed {
          removed.append(lines[lineIndex])
          lineIndex += 1
        }

        var added: [DiffLine] = []
        while lineIndex < lines.count && lines[lineIndex].kind == .added {
          added.append(lines[lineIndex])
          lineIndex += 1
        }

        let pairCount = max(removed.count, added.count)
        for pairIndex in 0..<pairCount {
          pairs.append(
            SideBySidePair(
              anchor: .sideBySidePair(fileID: fileID, ordinal: ordinal),
              left: pairIndex < removed.count ? removed[pairIndex] : nil,
              right: pairIndex < added.count ? added[pairIndex] : nil
            )
          )
          ordinal += 1
        }
      case .added:
        while lineIndex < lines.count && lines[lineIndex].kind == .added {
          pairs.append(
            SideBySidePair(
              anchor: .sideBySidePair(fileID: fileID, ordinal: ordinal),
              left: nil,
              right: lines[lineIndex]
            )
          )
          ordinal += 1
          lineIndex += 1
        }
      }
    }

    return pairs
  }
}
