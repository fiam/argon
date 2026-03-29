import Foundation
import Testing

@testable import Argon

@Suite("Diff Model")
struct DiffModelTests {

  @Test("FileDiff equality is by id")
  func fileDiffEqualityById() {
    let a = FileDiff(oldPath: "a.txt", newPath: "a.txt", hunks: [])
    let b = FileDiff(oldPath: "a.txt", newPath: "a.txt", hunks: [])

    // Two separately constructed FileDiffs have different UUIDs
    #expect(a != b)
    // A FileDiff equals itself
    #expect(a == a)
  }

  @Test("FileDiff hash is by id")
  func fileDiffHashById() {
    let a = FileDiff(oldPath: "x.rs", newPath: "x.rs", hunks: [])
    let b = FileDiff(oldPath: "x.rs", newPath: "x.rs", hunks: [])

    var set = Set<FileDiff>()
    set.insert(a)
    set.insert(b)

    // Both should be in the set since they have different ids
    #expect(set.count == 2)

    // Inserting the same instance again should not increase count
    set.insert(a)
    #expect(set.count == 2)
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
