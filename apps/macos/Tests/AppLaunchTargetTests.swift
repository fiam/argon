import XCTest

@testable import Argon

final class AppLaunchTargetTests: XCTestCase {
  func testCurrentReturnsNilWithoutCliSessionArguments() {
    XCTAssertNil(AppLaunchTarget.current(arguments: ["Argon"]))
  }

  func testCurrentParsesCliSessionArguments() {
    XCTAssertEqual(
      AppLaunchTarget.current(
        arguments: [
          "Argon",
          "--session-id", "session-123",
          "--repo-root", "/tmp/repo",
        ]
      ),
      .review(ReviewTarget(sessionId: "session-123", repoRoot: "/tmp/repo"))
    )
  }

  func testCurrentParsesWorkspaceArguments() {
    XCTAssertEqual(
      AppLaunchTarget.current(
        arguments: [
          "Argon",
          "--workspace-repo-root", "/tmp/repo",
          "--workspace-common-dir", "/tmp/repo/.git",
          "--selected-worktree-path", "/tmp/repo-worktrees/feature-a",
        ]
      ),
      .workspace(
        WorkspaceTarget(
          repoRoot: "/tmp/repo",
          repoCommonDir: "/tmp/repo/.git",
          selectedWorktreePath: "/tmp/repo-worktrees/feature-a"
        ))
    )
  }
}
