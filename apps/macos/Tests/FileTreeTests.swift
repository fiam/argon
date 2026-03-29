import Foundation
import Testing

@testable import Argon

@Suite("FileTree")
struct FileTreeTests {

  private func makeFile(_ path: String) -> FileDiff {
    FileDiff(oldPath: path, newPath: path, hunks: [])
  }

  @Test("builds tree from flat file list")
  func buildsTree() {
    let files = [
      makeFile("src/main.rs"),
      makeFile("src/lib.rs"),
      makeFile("README.md"),
    ]
    let tree = buildFileTree(from: files)

    // Should have src/ dir and README.md at root
    #expect(tree.count == 2)
    let dirNode = tree.first(where: { $0.isDirectory })!
    #expect(dirNode.name == "src")
    #expect(dirNode.children.count == 2)

    let fileNode = tree.first(where: { !$0.isDirectory })!
    #expect(fileNode.name == "README.md")
  }

  @Test("directories sort before files")
  func directoriesFirst() {
    let files = [
      makeFile("z.txt"),
      makeFile("a/b.txt"),
    ]
    let tree = buildFileTree(from: files)
    #expect(tree[0].isDirectory)
    #expect(!tree[1].isDirectory)
  }

  @Test("flattens single-child directory chains")
  func flattensSingleChild() {
    let files = [
      makeFile("a/b/c/file.txt")
    ]
    let tree = buildFileTree(from: files)
    // a/b/c/ should be flattened into one node
    #expect(tree.count == 1)
    #expect(tree[0].isDirectory)
    #expect(tree[0].name == "a/b/c")
    #expect(tree[0].children.count == 1)
    #expect(tree[0].children[0].name == "file.txt")
  }

  @Test("does not flatten when directory has multiple children")
  func doesNotFlattenMultipleChildren() {
    let files = [
      makeFile("a/b/x.txt"),
      makeFile("a/b/y.txt"),
    ]
    let tree = buildFileTree(from: files)
    #expect(tree.count == 1)
    let ab = tree[0]
    #expect(ab.name == "a/b")
    #expect(ab.children.count == 2)
  }

  @Test("file count aggregates through tree")
  func fileCountAggregates() {
    let files = [
      makeFile("src/a.rs"),
      makeFile("src/b.rs"),
      makeFile("README.md"),
    ]
    let tree = buildFileTree(from: files)
    let srcNode = tree.first(where: { $0.isDirectory })!
    #expect(srcNode.fileCount == 2)
  }
}

@Suite("Glob Filter")
struct GlobFilterTests {

  private func makeFile(_ path: String) -> FileDiff {
    FileDiff(oldPath: path, newPath: path, hunks: [])
  }

  private var files: [FileDiff] {
    [
      makeFile("src/main.rs"),
      makeFile("src/lib.rs"),
      makeFile("src/utils/helper.rs"),
      makeFile("tests/test_main.rs"),
      makeFile("README.md"),
      makeFile("Cargo.toml"),
    ]
  }

  @Test("empty pattern returns all files")
  func emptyPattern() {
    #expect(filterFiles(files, pattern: "").count == 6)
    #expect(filterFiles(files, pattern: "  ").count == 6)
  }

  @Test("star matches within single segment")
  func starMatch() {
    let result = filterFiles(files, pattern: "*.md")
    #expect(result.count == 1)
    #expect(result[0].displayPath == "README.md")
  }

  @Test("double star matches across segments")
  func doubleStarMatch() {
    let result = filterFiles(files, pattern: "**/*.rs")
    #expect(result.count == 4)
  }

  @Test("question mark matches single character")
  func questionMarkMatch() {
    let result = filterFiles(files, pattern: "src/??b.rs")
    #expect(result.count == 1)
    #expect(result[0].displayPath == "src/lib.rs")
  }

  @Test("pattern without wildcards matches exactly")
  func exactMatch() {
    let result = filterFiles(files, pattern: "README.md")
    #expect(result.count == 1)
  }

  @Test("partial name with star")
  func partialName() {
    let result = filterFiles(files, pattern: "**/test*")
    #expect(result.count == 1)
    #expect(result[0].displayPath == "tests/test_main.rs")
  }

  @Test("case insensitive matching")
  func caseInsensitive() {
    let result = filterFiles(files, pattern: "readme.md")
    #expect(result.count == 1)
  }
}
