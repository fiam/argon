import Testing

@testable import Argon

@Suite("DiffParser")
struct DiffParserTests {

  static let sampleDiff = """
    diff --git a/src/lib.rs b/src/lib.rs
    index 1111111..2222222 100644
    --- a/src/lib.rs
    +++ b/src/lib.rs
    @@ -1,3 +1,4 @@
     line1
    -line2
    +line2 changed
    +line3
     line4
    """

  @Test("parses file paths from diff header")
  func parsesFilePaths() {
    let files = DiffParser.parse(Self.sampleDiff)
    #expect(files.count == 1)
    #expect(files[0].oldPath == "src/lib.rs")
    #expect(files[0].newPath == "src/lib.rs")
  }

  @Test("parses hunks with correct line numbers")
  func parsesHunks() {
    let files = DiffParser.parse(Self.sampleDiff)
    let hunk = files[0].hunks[0]
    #expect(hunk.oldStart == 1)
    #expect(hunk.newStart == 1)
    #expect(hunk.lines.count == 5)
  }

  @Test("identifies context, added, and removed lines")
  func identifiesLineKinds() {
    let files = DiffParser.parse(Self.sampleDiff)
    let lines = files[0].hunks[0].lines

    #expect(lines[0].kind == .context)
    #expect(lines[0].oldLine == 1)
    #expect(lines[0].newLine == 1)

    #expect(lines[1].kind == .removed)
    #expect(lines[1].oldLine == 2)
    #expect(lines[1].newLine == nil)

    #expect(lines[2].kind == .added)
    #expect(lines[2].oldLine == nil)
    #expect(lines[2].newLine == 2)

    #expect(lines[3].kind == .added)
    #expect(lines[3].newLine == 3)

    #expect(lines[4].kind == .context)
    #expect(lines[4].oldLine == 3)
    #expect(lines[4].newLine == 4)
  }

  @Test("parses multiple files")
  func parsesMultipleFiles() {
    let diff = """
      diff --git a/a.txt b/a.txt
      --- a/a.txt
      +++ b/a.txt
      @@ -1 +1 @@
      -old
      +new
      diff --git a/b.txt b/b.txt
      --- a/b.txt
      +++ b/b.txt
      @@ -1 +1,2 @@
       keep
      +added
      """
    let files = DiffParser.parse(diff)
    #expect(files.count == 2)
    #expect(files[0].newPath == "a.txt")
    #expect(files[1].newPath == "b.txt")
  }

  @Test("handles empty diff")
  func handlesEmptyDiff() {
    let files = DiffParser.parse("")
    #expect(files.isEmpty)
  }

  @Test("ignores no-newline-at-end-of-file marker")
  func ignoresNoNewlineMarker() {
    let diff = """
      diff --git a/a.txt b/a.txt
      --- a/a.txt
      +++ b/a.txt
      @@ -1 +1 @@
      -old
      +new
      \\ No newline at end of file
      """
    let files = DiffParser.parse(diff)
    #expect(files[0].hunks[0].lines.count == 2)
  }

  @Test("skips metadata lines")
  func skipsMetadata() {
    let diff = """
      diff --git a/a.txt b/a.txt
      new file mode 100644
      index 0000000..1234567
      --- /dev/null
      +++ b/a.txt
      @@ -0,0 +1 @@
      +hello
      """
    let files = DiffParser.parse(diff)
    #expect(files.count == 1)
    #expect(files[0].hunks[0].lines.count == 1)
    #expect(files[0].hunks[0].lines[0].kind == .added)
  }
}
