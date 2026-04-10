import Foundation
import Testing

@testable import Argon

@Suite("Diff Model")
struct DiffModelTests {

  @Test("FileDiff equality is by path")
  func fileDiffEqualityByPath() {
    let a = FileDiff(oldPath: "a.txt", newPath: "a.txt", hunks: [])
    let b = FileDiff(oldPath: "a.txt", newPath: "a.txt", hunks: [])
    let c = FileDiff(oldPath: "b.txt", newPath: "b.txt", hunks: [])

    // Same newPath means equal
    #expect(a == b)
    // Different newPath means not equal
    #expect(a != c)
  }

  @Test("FileDiff hash is by path")
  func fileDiffHashByPath() {
    let a = FileDiff(oldPath: "x.rs", newPath: "x.rs", hunks: [])
    let b = FileDiff(oldPath: "x.rs", newPath: "x.rs", hunks: [])

    var set = Set<FileDiff>()
    set.insert(a)
    set.insert(b)

    // Same path = same identity, so only one in the set
    #expect(set.count == 1)
  }

  @Test("FileDiff id is stable from path")
  func fileDiffStableId() {
    let a = FileDiff(oldPath: "foo.txt", newPath: "foo.txt", hunks: [])
    let b = FileDiff(oldPath: "foo.txt", newPath: "foo.txt", hunks: [])
    #expect(a.id == b.id)
    #expect(a.id == "foo.txt")
  }

  @Test("displayPath returns newPath")
  func displayPathReturnsNewPath() {
    let diff = FileDiff(oldPath: "old/path.swift", newPath: "new/path.swift", hunks: [])
    #expect(diff.displayPath == "new/path.swift")
  }

  @Test("DiffLine kinds are correct")
  func diffLineKinds() {
    let context = DiffLine(kind: .context, content: " unchanged", oldLine: 1, newLine: 1)
    let added = DiffLine(kind: .added, content: "+new line", oldLine: nil, newLine: 2)
    let removed = DiffLine(kind: .removed, content: "-old line", oldLine: 2, newLine: nil)

    #expect(context.kind == .context)
    #expect(added.kind == .added)
    #expect(removed.kind == .removed)

    #expect(context.oldLine == 1)
    #expect(context.newLine == 1)
    #expect(added.oldLine == nil)
    #expect(added.newLine == 2)
    #expect(removed.oldLine == 2)
    #expect(removed.newLine == nil)
  }

  @Test("DiffLine anchors are stable within a file")
  func diffLineAnchorsAreStable() {
    let fileA = FileDiff(
      oldPath: "foo.txt",
      newPath: "foo.txt",
      hunks: [
        DiffHunk(
          header: "@@ -1 +1 @@",
          oldStart: 1,
          newStart: 1,
          lines: [DiffLine(kind: .context, content: "same", oldLine: 1, newLine: 1)]
        )
      ]
    )
    let fileB = FileDiff(
      oldPath: "foo.txt",
      newPath: "foo.txt",
      hunks: [
        DiffHunk(
          header: "@@ -1 +1 @@",
          oldStart: 1,
          newStart: 1,
          lines: [DiffLine(kind: .context, content: "same", oldLine: 1, newLine: 1)]
        )
      ]
    )

    #expect(fileA.hunks[0].anchor == fileB.hunks[0].anchor)
    #expect(fileA.hunks[0].lines[0].anchor == fileB.hunks[0].lines[0].anchor)
  }

  @Test("split side prefers the single-sided column")
  func splitSidePrefersSingleSidedColumn() {
    let removed = DiffLine(kind: .removed, content: "old", oldLine: 3, newLine: nil)
    let added = DiffLine(kind: .added, content: "new", oldLine: nil, newLine: 4)
    let context = DiffLine(kind: .context, content: "same", oldLine: 5, newLine: 5)

    #expect(removed.preferredSplitSide == .left)
    #expect(added.preferredSplitSide == .right)
    #expect(context.preferredSplitSide == nil)

    let oldAnchor = CommentAnchor(filePath: "foo.swift", lineNew: nil, lineOld: 8)
    let newAnchor = CommentAnchor(filePath: "foo.swift", lineNew: 9, lineOld: nil)
    let sharedAnchor = CommentAnchor(filePath: "foo.swift", lineNew: 10, lineOld: 10)

    #expect(oldAnchor.preferredSplitSide == .left)
    #expect(newAnchor.preferredSplitSide == .right)
    #expect(sharedAnchor.preferredSplitSide == nil)
  }

  @Test("side by side pair is unchanged only when both panes share the same anchor")
  func sideBySidePairUnchangedDetection() {
    let shared = DiffLine(kind: .context, content: "same", oldLine: 10, newLine: 10)
    let unchangedPair = SideBySidePair(left: shared, right: shared)
    let changedPair = SideBySidePair(
      left: DiffLine(kind: .removed, content: "old", oldLine: 11, newLine: nil),
      right: DiffLine(kind: .added, content: "new", oldLine: nil, newLine: 11)
    )

    #expect(unchangedPair.isUnchangedPair)
    #expect(!changedPair.isUnchangedPair)
    #expect(changedPair.visualKind(for: .left) == .removed)
    #expect(changedPair.visualKind(for: .right) == .added)

    let rightOnlyPair = SideBySidePair(
      left: nil,
      right: DiffLine(kind: .added, content: "inserted", oldLine: nil, newLine: 12)
    )
    #expect(rightOnlyPair.visualKind(for: .left) == .added)
    #expect(rightOnlyPair.visualKind(for: .right) == .added)
  }
}
