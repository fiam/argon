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
}
