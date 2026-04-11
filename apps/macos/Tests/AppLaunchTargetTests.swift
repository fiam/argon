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
      ReviewTarget(sessionId: "session-123", repoRoot: "/tmp/repo")
    )
  }
}
