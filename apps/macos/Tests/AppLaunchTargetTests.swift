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

  func testCurrentParsesReviewLaunchContext() {
    XCTAssertEqual(
      AppLaunchTarget.current(
        arguments: [
          "Argon",
          "--session-id", "session-123",
          "--repo-root", "/tmp/repo",
          "--review-launch-context", "coderHandoff",
        ]
      ),
      .review(
        ReviewTarget(
          sessionId: "session-123",
          repoRoot: "/tmp/repo",
          launchContext: .coderHandoff
        ))
    )
  }

  func testCurrentParsesExternalReviewLaunchContext() {
    XCTAssertEqual(
      AppLaunchTarget.current(
        arguments: [
          "Argon",
          "--session-id", "session-123",
          "--repo-root", "/tmp/repo",
          "--review-launch-context", "externalHandoff",
        ]
      ),
      .review(
        ReviewTarget(
          sessionId: "session-123",
          repoRoot: "/tmp/repo",
          launchContext: .externalHandoff
        ))
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

  func testRequestParsesWorkspaceURL() throws {
    let url = try XCTUnwrap(
      URL(
        string:
          "argon://workspace?repo-root=%2Ftmp%2Frepo&repo-common-dir=%2Ftmp%2Frepo%2F.git&selected-worktree-path=%2Ftmp%2Frepo-worktrees%2Ffeature-a"
      ))

    XCTAssertEqual(
      AppLaunchTarget.request(from: url),
      .workspace(
        WorkspaceTarget(
          repoRoot: "/tmp/repo",
          repoCommonDir: "/tmp/repo/.git",
          selectedWorktreePath: "/tmp/repo-worktrees/feature-a"
        ))
    )
  }

  func testRequestParsesReviewURL() throws {
    let url = try XCTUnwrap(
      URL(
        string:
          "argon://review?session-id=session-123&repo-root=%2Ftmp%2Frepo&review-launch-context=externalHandoff"
      ))

    XCTAssertEqual(
      AppLaunchTarget.request(from: url),
      .review(
        ReviewTarget(
          sessionId: "session-123",
          repoRoot: "/tmp/repo",
          launchContext: .externalHandoff
        ))
    )
  }

  func testRequestRejectsUnknownURLScheme() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com"))

    XCTAssertNil(AppLaunchTarget.request(from: url))
  }
}
