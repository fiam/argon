import Testing

@testable import Argon

@Suite("GhosttyWakeupCoalescer")
struct GhosttyWakeupCoalescerTests {
  @Test("schedule coalesces duplicate keys until execution begins")
  func scheduleCoalescesDuplicateKeysUntilExecutionBegins() {
    let coalescer = GhosttyWakeupCoalescer()

    #expect(coalescer.schedule(7))
    #expect(!coalescer.schedule(7))

    coalescer.beginExecuting(7)

    #expect(coalescer.schedule(7))
  }

  @Test("schedule keeps independent keys separate")
  func scheduleKeepsIndependentKeysSeparate() {
    let coalescer = GhosttyWakeupCoalescer()

    #expect(coalescer.schedule(1))
    #expect(coalescer.schedule(2))
    #expect(!coalescer.schedule(1))
    #expect(!coalescer.schedule(2))
  }
}
