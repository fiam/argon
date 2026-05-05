import Testing

@testable import Argon

@Suite("AppRuntimeMode")
struct AppRuntimeModeTests {
  @Test("defaults to normal mode")
  func defaultsToNormalMode() {
    #expect(AppRuntimeMode.current(environment: [:]) == .normal)
  }

  @Test("detects app-hosted unit test mode")
  func detectsAppHostedUnitTestMode() {
    #expect(
      AppRuntimeMode.current(
        environment: [AppRuntimeMode.appHostedUnitTestsEnvironmentKey: "1"])
        == .appHostedUnitTests)
    #expect(
      AppRuntimeMode.current(
        environment: [AppRuntimeMode.appHostedUnitTestsEnvironmentKey: "yes"])
        .suppressesVisibleAppHost)
    #expect(
      AppRuntimeMode.current(
        environment: [AppRuntimeMode.appHostedUnitTestsEnvironmentKey: "false"])
        == .normal)
  }
}
