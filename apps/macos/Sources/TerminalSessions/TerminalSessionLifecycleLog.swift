import Darwin
import Foundation

enum TerminalSessionLifecycleLog {
  private static let lock = NSLock()

  static func record(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["ARGON_TERMINAL_LIFECYCLE_LOG"] != nil else {
      return
    }

    let line =
      "\(ISO8601DateFormatter().string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(message())\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-terminal-lifecycle-\(getuid()).log", isDirectory: false)

    lock.lock()
    defer { lock.unlock() }

    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    _ = try? handle.write(contentsOf: data)
  }
}
