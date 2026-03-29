import Foundation
import Testing

@testable import Argon

@Suite("SessionLoader")
struct SessionLoaderTests {

  @Test("repo storage key is deterministic")
  func repoStorageKeyIsDeterministic() {
    // The FNV-1a hash should produce the same key for the same path
    let key1 = testRepoStorageKey("/tmp/test-repo")
    let key2 = testRepoStorageKey("/tmp/test-repo")
    #expect(key1 == key2)
  }

  @Test("repo storage key differs for different paths")
  func repoStorageKeyDiffers() {
    let key1 = testRepoStorageKey("/tmp/repo-a")
    let key2 = testRepoStorageKey("/tmp/repo-b")
    #expect(key1 != key2)
  }

  @Test("repo storage key sanitizes name")
  func repoStorageKeySanitizes() {
    let key = testRepoStorageKey("/tmp/My Project (2)")
    // Should only contain lowercase alphanumeric, hyphens, underscores
    let name = key.split(separator: "-").dropLast().joined(separator: "-")
    let valid = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    #expect(valid)
    #expect(name == name.lowercased())
  }

  // Mirror the SessionLoader's private methods for testing
  private func testRepoStorageKey(_ repoRoot: String) -> String {
    let url = URL(fileURLWithPath: repoRoot)
    let resolved = url.standardizedFileURL.path
    let name = URL(fileURLWithPath: resolved).lastPathComponent
    let sanitized = sanitizeRepoName(name)
    let repoName = sanitized.isEmpty ? "repo" : sanitized
    let hash = fnv1a64(Array(resolved.utf8))
    return "\(repoName)-\(String(format: "%016llx", hash))"
  }

  private func sanitizeRepoName(_ name: String) -> String {
    String(
      name.compactMap { ch -> Character? in
        let lower = ch.lowercased().first!
        if lower.isASCII && (lower.isLetter || lower.isNumber || lower == "-" || lower == "_") {
          return lower
        }
        return nil
      })
  }

  private func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return hash
  }
}
