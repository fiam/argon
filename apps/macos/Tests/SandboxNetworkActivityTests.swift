import Foundation
import Testing

@testable import Argon

@Suite("SandboxNetworkActivity")
struct SandboxNetworkActivityTests {

  @Test("log path uses the temporary sandbox network directory")
  func logPathUsesTemporarySandboxNetworkDirectory() {
    let tabID = UUID(uuidString: "3C270C64-3553-4E21-B0DB-8EF874BF7EB5")!
    let url = SandboxNetworkActivityLogStore.logURL(for: tabID)

    #expect(url.lastPathComponent == "3c270c64-3553-4e21-b0db-8ef874bf7eb5.ndjson")
    #expect(url.path.contains("/argon-sandbox-network/"))
  }

  @Test("loader parses ndjson proxy activity")
  func loaderParsesNDJSONProxyActivity() throws {
    let tabID = UUID(uuidString: "D24B0485-2294-47BE-A429-673E9F9C2B70")!
    let url = SandboxNetworkActivityLogStore.logURL(for: tabID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
        {"occurred_at":"2026-04-21T10:11:12.123Z","kind":"http","outcome":"proxied","method":"GET","host":"api.openai.com","port":443,"path":"/v1/models","detail":null,"bytes_up":321,"bytes_down":6543}
        {"occurred_at":"2026-04-21T10:11:13.123Z","kind":"connect","outcome":"denied","method":"CONNECT","host":"blocked.example.com","port":443,"path":null,"detail":"proxy access denied by Sandboxfile","bytes_up":0,"bytes_down":0}
    """
    .write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let events = SandboxNetworkActivityLogStore.loadEvents(for: tabID)

    #expect(events.count == 2)
    #expect(events.first?.host == "api.openai.com")
    #expect(events.first?.bytesUp == 321)
    #expect(events.last?.outcome == "denied")
    #expect(events.last?.path == nil)
  }
}
