import XCTest

@testable import Argon

final class MainActorDispatchTests: XCTestCase {
  func testSyncRunsOnMainThreadWhenCalledFromMainThread() {
    let isMainThread = MainActorDispatch.sync {
      Thread.isMainThread
    }

    XCTAssertTrue(isMainThread)
  }

  func testSyncRunsOnMainThreadWhenCalledFromBackgroundThread() {
    let expectation = expectation(description: "sync hops to main thread")

    DispatchQueue.global().async {
      let isMainThread = MainActorDispatch.sync {
        Thread.isMainThread
      }

      XCTAssertTrue(isMainThread)
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1)
  }

  func testAsyncRunsOnMainThreadWhenCalledFromBackgroundThread() {
    let expectation = expectation(description: "async hops to main thread")

    DispatchQueue.global().async {
      MainActorDispatch.async {
        XCTAssertTrue(Thread.isMainThread)
        expectation.fulfill()
      }
    }

    wait(for: [expectation], timeout: 1)
  }
}
