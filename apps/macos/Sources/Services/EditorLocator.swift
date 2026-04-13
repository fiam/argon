import AppKit
import Foundation

struct DetectedEditorApp: Identifiable, Hashable {
  let bundleIdentifier: String
  let displayName: String
  let applicationURL: URL

  var id: String { bundleIdentifier }
}

enum EditorLocator {
  private static let candidateBundleIdentifiers = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.todesktop.230313mzl4w4u92",
    "com.exafunction.windsurf",
    "dev.zed.Zed",
    "dev.zed.Zed-Preview",
    "com.vscodium",
    "com.apple.dt.Xcode",
    "com.panic.Nova",
    "com.sublimetext.4",
    "com.jetbrains.intellij",
    "com.jetbrains.intellij.ce",
    "com.jetbrains.WebStorm",
    "com.jetbrains.PyCharm",
    "com.jetbrains.PyCharmCE",
    "com.jetbrains.CLion",
    "com.jetbrains.GoLand",
    "com.jetbrains.RubyMine",
    "com.jetbrains.DataGrip",
    "com.jetbrains.PhpStorm",
    "com.jetbrains.Rider",
  ]

  static func discoverInstalledEditors(
    applicationURLForBundleID: (String) -> URL? = {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    },
    displayNameForApplicationURL: (URL) -> String = defaultDisplayName(for:)
  ) -> [DetectedEditorApp] {
    var seenBundleIdentifiers = Set<String>()

    return
      candidateBundleIdentifiers
      .compactMap { bundleIdentifier in
        guard seenBundleIdentifiers.insert(bundleIdentifier).inserted else { return nil }
        guard let applicationURL = applicationURLForBundleID(bundleIdentifier) else { return nil }
        return DetectedEditorApp(
          bundleIdentifier: bundleIdentifier,
          displayName: displayNameForApplicationURL(applicationURL),
          applicationURL: applicationURL
        )
      }
  }

  static func icon(for editor: DetectedEditorApp, size: CGFloat = 32) -> NSImage {
    let icon = NSWorkspace.shared.icon(forFile: editor.applicationURL.path)
    icon.size = NSSize(width: size, height: size)
    return icon
  }

  static func open(_ editor: DetectedEditorApp, worktreePath: String) async throws {
    try await open(editor, urls: [URL(fileURLWithPath: worktreePath)])
  }

  static func open(_ editor: DetectedEditorApp, urls: [URL]) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = true

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.open(
        urls,
        withApplicationAt: editor.applicationURL,
        configuration: configuration
      ) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private static func defaultDisplayName(for applicationURL: URL) -> String {
    if let bundle = Bundle(url: applicationURL) {
      for key in ["CFBundleDisplayName", kCFBundleNameKey as String, "CFBundleExecutable"] {
        if let value = bundle.object(forInfoDictionaryKey: key) as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return value
        }
      }
    }

    return applicationURL.deletingPathExtension().lastPathComponent
  }
}
