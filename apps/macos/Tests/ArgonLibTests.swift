import Testing

@testable import Argon

@Suite("ArgonLib")
struct ArgonLibTests {
  @Test("highlightedText returns Swift styled spans")
  func highlightedTextReturnsStyledSpans() throws {
    let lines = try ArgonLib.highlightedText(
      text: "let value = 1\n",
      path: "src/lib.rs",
      theme: "base16-ocean.dark"
    )

    #expect(lines.count == 2)
    #expect(lines[0].map(\.text).joined() == "let value = 1")
    #expect(lines[0].contains { $0.fg != nil })
  }

  @Test("highlightedDiff surfaces argon-lib errors")
  func highlightedDiffSurfacesErrors() {
    do {
      _ = try ArgonLib.highlightedDiff(
        sessionId: "not-a-uuid",
        repoRoot: "/tmp",
        theme: "base16-ocean.dark"
      )
      Issue.record("Expected highlightedDiff to throw")
    } catch {
      #expect(String(describing: error).contains("invalid session id"))
    }
  }
}
