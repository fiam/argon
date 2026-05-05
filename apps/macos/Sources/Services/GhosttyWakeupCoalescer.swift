import Foundation

final class GhosttyWakeupCoalescer: @unchecked Sendable {
  static let shared = GhosttyWakeupCoalescer()

  private let lock = NSLock()
  private var scheduledKeys: Set<UInt> = []

  func schedule(_ key: UInt) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    guard !scheduledKeys.contains(key) else { return false }
    scheduledKeys.insert(key)
    return true
  }

  func beginExecuting(_ key: UInt) {
    lock.lock()
    scheduledKeys.remove(key)
    lock.unlock()
  }
}
