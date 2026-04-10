import Foundation
import Testing

@testable import Argon

@Suite("DiffDocument")
struct DiffDocumentTests {

  @Test("builder flattens unified rows with stable anchors")
  func flattensUnifiedRows() {
    let file = makeFile(
      path: "Sources/Foo.swift",
      lines: [
        DiffLine(kind: .context, content: "let foo = 1", oldLine: 1, newLine: 1),
        DiffLine(kind: .added, content: "let bar = 2", oldLine: nil, newLine: 2),
      ]
    )

    let firstLine = file.hunks[0].lines[0]
    let document = DiffDocumentBuilder.build(
      files: [file],
      session: nil,
      pendingDrafts: [],
      diffMode: .unified,
      activeCommentLineID: firstLine.id
    )

    #expect(
      document.rows.map(\.kind)
        == [
          .fileHeader,
          .hunkHeader,
          .unifiedLine,
          .commentEditor,
          .unifiedLine,
        ]
    )
    #expect(document.contains(anchor: file.anchor))
    #expect(document.contains(anchor: file.hunks[0].anchor))
    #expect(document.contains(anchor: firstLine.anchor))
    #expect(document.contains(anchor: .commentEditor(forLineID: firstLine.id)))
    #expect(document.row(for: .commentEditor(forLineID: firstLine.id))?.placement == .fullWidth)
  }

  @Test("builder includes orphaned threads and inline attachments")
  func includesThreadAndDraftRows() {
    let file = makeFile(
      path: "Sources/Foo.swift",
      lines: [
        DiffLine(kind: .context, content: "let foo = 1", oldLine: 1, newLine: 1),
        DiffLine(kind: .added, content: "let bar = 2", oldLine: nil, newLine: 2),
      ]
    )

    let inlineThread = makeThread(
      threadID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1")!,
      commentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2")!,
      filePath: file.newPath,
      lineNew: 1
    )
    let orphanedThread = makeThread(
      threadID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE5")!,
      commentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE6")!,
      filePath: "Sources/Elsewhere.swift",
      lineNew: 9
    )
    let draft = makeDraft(filePath: file.newPath, lineNew: 2)
    let session = makeSession(threads: [inlineThread, orphanedThread])

    let document = DiffDocumentBuilder.build(
      files: [file],
      session: session,
      pendingDrafts: [draft],
      diffMode: .unified,
      activeCommentLineID: nil
    )

    #expect(document.rows.first?.kind == .orphanedThread)
    #expect(document.row(for: .thread(orphanedThread.id))?.kind == .orphanedThread)
    #expect(document.row(for: .thread(inlineThread.id))?.kind == .inlineThread(isOutdated: false))
    #expect(document.row(for: .draft(draft.id))?.kind == .inlineDraft)
  }

  @Test("side by side rows are addressable by line anchors")
  func sideBySideRowsResolveLineAnchors() {
    let left = DiffLine(kind: .removed, content: "old", oldLine: 1, newLine: nil)
    let right = DiffLine(kind: .added, content: "new", oldLine: nil, newLine: 1)
    let file = FileDiff(
      oldPath: "Sources/Foo.swift",
      newPath: "Sources/Foo.swift",
      hunks: [],
      sideBySide: [SideBySidePair(left: left, right: right)]
    )

    let document = DiffDocumentBuilder.build(
      files: [file],
      session: nil,
      pendingDrafts: [],
      diffMode: .sideBySide,
      activeCommentLineID: nil
    )

    #expect(document.row(for: file.sideBySide[0].left!.anchor)?.kind == .sideBySidePair)
    #expect(document.row(for: file.sideBySide[0].right!.anchor)?.kind == .sideBySidePair)
  }

  @Test("side by side rows support comments and attachments on the left side")
  func sideBySideRowsSupportLeftSideComments() {
    let left = DiffLine(kind: .removed, content: "old", oldLine: 7, newLine: nil)
    let file = FileDiff(
      oldPath: "Sources/Foo.swift",
      newPath: "Sources/Foo.swift",
      hunks: [],
      sideBySide: [SideBySidePair(left: left, right: nil)]
    )
    let thread = makeThread(
      threadID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE7")!,
      commentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE8")!,
      filePath: file.newPath,
      lineNew: nil,
      lineOld: 7
    )
    let draft = makeDraft(filePath: file.newPath, lineNew: nil, lineOld: 7)
    let session = makeSession(threads: [thread])

    let document = DiffDocumentBuilder.build(
      files: [file],
      session: session,
      pendingDrafts: [draft],
      diffMode: .sideBySide,
      activeCommentLineID: file.sideBySide[0].left?.id
    )

    #expect(document.row(for: file.sideBySide[0].left!.anchor)?.kind == .sideBySidePair)
    #expect(document.contains(anchor: .commentEditor(forLineID: file.sideBySide[0].left!.id)))
    #expect(document.row(for: .thread(thread.id))?.kind == .inlineThread(isOutdated: false))
    #expect(document.row(for: .draft(draft.id))?.kind == .inlineDraft)
    #expect(
      document.row(for: .commentEditor(forLineID: file.sideBySide[0].left!.id))?.placement
        == .split(side: .left)
    )
    #expect(document.row(for: .thread(thread.id))?.placement == .split(side: .left))
    #expect(document.row(for: .draft(draft.id))?.placement == .split(side: .left))
  }

  private func makeFile(path: String, lines: [DiffLine]) -> FileDiff {
    let hunk = DiffHunk(header: "@@ -1,1 +1,2 @@", oldStart: 1, newStart: 1, lines: lines)
    return FileDiff(oldPath: path, newPath: path, hunks: [hunk])
  }

  private func makeThread(
    threadID: UUID,
    commentID: UUID,
    filePath: String,
    lineNew: UInt32? = nil,
    lineOld: UInt32? = nil
  ) -> ReviewThread {
    let comment = ReviewComment(
      id: commentID,
      threadId: threadID,
      author: .reviewer,
      authorName: nil,
      kind: .line,
      anchor: CommentAnchor(filePath: filePath, lineNew: lineNew, lineOld: lineOld),
      body: "Check this",
      createdAt: Date(timeIntervalSince1970: 1)
    )
    return ReviewThread(
      id: threadID,
      state: .open,
      agentAcknowledgedAt: nil,
      comments: [comment]
    )
  }

  private func makeDraft(
    filePath: String,
    lineNew: UInt32? = nil,
    lineOld: UInt32? = nil
  ) -> DraftComment {
    DraftComment(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE3")!,
      threadId: nil,
      anchor: CommentAnchor(filePath: filePath, lineNew: lineNew, lineOld: lineOld),
      body: "Pending draft",
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
  }

  private func makeSession(threads: [ReviewThread]) -> ReviewSession {
    ReviewSession(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE4")!,
      repoRoot: "/tmp/repo",
      mode: .commit,
      baseRef: "HEAD",
      headRef: "WORKTREE",
      mergeBaseSha: "deadbeef",
      changeSummary: nil,
      status: .awaitingReviewer,
      threads: threads,
      decision: nil,
      agentLastSeenAt: nil,
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
  }
}
