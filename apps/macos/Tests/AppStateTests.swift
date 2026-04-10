import Foundation
import Testing

@testable import Argon

@MainActor
@Suite("AppState")
struct AppStateTests {

  @Test("selectFile matches both file id and path")
  func selectFileMatchesIdAndPath() {
    let state = AppState()
    let first = makeFile(path: "Sources/First.swift", lineText: "first")
    let second = makeFile(path: "Sources/Second.swift", lineText: "second")
    state.files = [first, second]

    let byPath = state.selectFile(matching: second.newPath)
    #expect(byPath?.id == second.id)
    #expect(state.selectedFile?.id == second.id)

    let byId = state.selectFile(matching: first.id)
    #expect(byId?.id == first.id)
    #expect(state.selectedFile?.id == first.id)
  }

  @Test("navigating to a search match selects its file")
  func searchNavigationSelectsMatchingFile() {
    let state = AppState()
    let first = makeFile(path: "Sources/First.swift", lineText: "first")
    let second = makeFile(path: "Sources/Second.swift", lineText: "needle")
    state.files = [first, second]
    state.selectedFile = first
    state.searchMatches = [
      SearchMatch(anchor: second.hunks[0].lines[0].anchor, filePath: second.newPath)
    ]

    state.navigateToNextMatch()

    #expect(state.selectedFile?.id == second.id)
    #expect(state.diffNavigationRequest?.anchor == second.hunks[0].lines[0].anchor)
    #expect(state.diffNavigationRequest?.fallbackFileID == second.id)
  }

  private func makeFile(path: String, lineText: String) -> FileDiff {
    let line = DiffLine(kind: .added, content: lineText, oldLine: nil, newLine: 1)
    let hunk = DiffHunk(header: "@@ -0,0 +1 @@", oldStart: 0, newStart: 1, lines: [line])
    return FileDiff(oldPath: path, newPath: path, hunks: [hunk])
  }
}
