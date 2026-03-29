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

@Suite("Fuzzy Filter")
struct FuzzyFilterTests {

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

  @Test("fuzzy matches characters in order")
  func fuzzyBasic() {
    // "mr" matches src/main.rs (m...r in path)
    let result = filterFiles(files, pattern: "mr")
    #expect(result.contains(where: { $0.displayPath == "src/main.rs" }))
  }

  @Test("fuzzy is case insensitive")
  func fuzzyCaseInsensitive() {
    let result = filterFiles(files, pattern: "readme")
    #expect(result.count == 1)
    #expect(result[0].displayPath == "README.md")
  }

  @Test("fuzzy matches across path segments")
  func fuzzyAcrossSegments() {
    // "uh" matches src/utils/helper.rs
    let result = filterFiles(files, pattern: "uh")
    #expect(result.contains(where: { $0.displayPath == "src/utils/helper.rs" }))
  }

  @Test("fuzzy ranks exact filename higher")
  func fuzzyRanking() {
    // "main" should rank src/main.rs above tests/test_main.rs
    let result = filterFiles(files, pattern: "main")
    #expect(result.count >= 2)
    #expect(result[0].displayPath == "src/main.rs")
  }

  @Test("fuzzy no match returns empty")
  func fuzzyNoMatch() {
    let result = filterFiles(files, pattern: "zzzzz")
    #expect(result.isEmpty)
  }

  @Test("fuzzy with extension")
  func fuzzyExtension() {
    let result = filterFiles(files, pattern: ".toml")
    #expect(result.count == 1)
    #expect(result[0].displayPath == "Cargo.toml")
  }
}

@Suite("Regex Filter")
struct RegexFilterTests {

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

  @Test("regex mode triggered by / prefix")
  func regexMode() {
    let result = filterFiles(files, pattern: "/\\.rs$")
    #expect(result.count == 4)
  }

  @Test("regex case insensitive")
  func regexCaseInsensitive() {
    let result = filterFiles(files, pattern: "/readme")
    #expect(result.count == 1)
  }

  @Test("regex with groups")
  func regexGroups() {
    // Matches src/main.rs, src/lib.rs, tests/test_main.rs
    let result = filterFiles(files, pattern: "/(main|lib)\\.rs")
    #expect(result.count == 3)
  }

  @Test("empty regex returns all")
  func emptyRegex() {
    let result = filterFiles(files, pattern: "/")
    #expect(result.count == 6)
  }

  @Test("invalid regex returns empty gracefully")
  func invalidRegex() {
    let result = filterFiles(files, pattern: "/[invalid")
    #expect(result.isEmpty)
  }
}

@Suite("Fuzzy Match Scoring")
struct FuzzyMatchScoringTests {

  @Test("consecutive matches score higher")
  func consecutiveBonus() {
    let (m1, s1) = fuzzyMatch("abcdef", query: "abc")
    let (m2, s2) = fuzzyMatch("axbxcx", query: "abc")
    #expect(m1)
    #expect(m2)
    #expect(s1 > s2)
  }

  @Test("segment start matches score higher")
  func segmentStartBonus() {
    let (m1, s1) = fuzzyMatch("src/main.rs", query: "m")
    let (m2, s2) = fuzzyMatch("summer", query: "m")
    #expect(m1)
    #expect(m2)
    #expect(s1 > s2)
  }

  @Test("non-match returns false")
  func nonMatch() {
    let (matches, _) = fuzzyMatch("hello", query: "xyz")
    #expect(!matches)
  }
}

@Suite("Mode Detection")
struct ModeDetectionTests {

  @Test("plain text is fuzzy")
  func plainTextIsFuzzy() {
    #expect(detectFilterMode("main") == .fuzzy)
    #expect(detectFilterMode("src/lib") == .fuzzy)
  }

  @Test("wildcards trigger glob")
  func wildcardsAreGlob() {
    #expect(detectFilterMode("*.rs") == .glob)
    #expect(detectFilterMode("src/**") == .glob)
    #expect(detectFilterMode("te?t") == .glob)
  }

  @Test("leading slash is regex")
  func slashIsRegex() {
    #expect(detectFilterMode("/\\.rs$") == .regex)
    #expect(detectFilterMode("/main") == .regex)
  }

  @Test("empty is fuzzy")
  func emptyIsFuzzy() {
    #expect(detectFilterMode("") == .fuzzy)
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

  @Test("partial name with star")
  func partialName() {
    let result = filterFiles(files, pattern: "**/test*")
    #expect(result.count == 1)
    #expect(result[0].displayPath == "tests/test_main.rs")
  }
}
