import Darwin
import XCTest

@testable import Argon

final class AppSignalHandlingTests: XCTestCase {
  func testInstallEmbeddedTerminalHandlersIgnoresSIGHUP() {
    var installedSignal: Int32?
    var installedHandlerRaw: Int?
    var installerCalled = false

    AppSignalHandling.installEmbeddedTerminalHandlers { signal, handler in
      installerCalled = true
      installedSignal = signal
      if let handler {
        installedHandlerRaw = unsafeBitCast(handler, to: Int.self)
      } else {
        installedHandlerRaw = nil
      }
      return nil
    }

    XCTAssertTrue(installerCalled)
    XCTAssertEqual(installedSignal, SIGHUP)
    XCTAssertEqual(installedHandlerRaw, unsafeBitCast(SIG_IGN, to: Int.self))
  }
}
