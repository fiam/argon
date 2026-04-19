import Foundation

enum SandboxfileSettingsLayer: String, CaseIterable, Identifiable, Sendable {
  case project
  case personal

  var id: String { rawValue }

  var title: String {
    switch self {
    case .project:
      "Project"
    case .personal:
      "Personal"
    }
  }
}

struct SandboxfileSettingsSource: Identifiable, Equatable, Sendable {
  let order: Int
  let path: String
  let title: String
  let subtitle: String
  let contents: String

  var id: String { path }

  var menuTitle: String {
    "\(order). \(title) - \(subtitle)"
  }

  var highlightPath: String {
    "sandbox.sh"
  }
}

struct SandboxfileSettingsSnapshot: Equatable, Sendable {
  let rootPath: String
  let initPath: String?
  let projectSources: [SandboxfileSettingsSource]
  let userSources: [SandboxfileSettingsSource]

  var sources: [SandboxfileSettingsSource] {
    projectSources + userSources
  }

  func sources(for layer: SandboxfileSettingsLayer) -> [SandboxfileSettingsSource] {
    switch layer {
    case .project:
      projectSources
    case .personal:
      userSources
    }
  }

  func editableSource(for layer: SandboxfileSettingsLayer) -> SandboxfileSettingsSource? {
    sources(for: layer).first
  }

  func inheritedSourceCount(for layer: SandboxfileSettingsLayer) -> Int {
    max(0, sources(for: layer).count - 1)
  }

  func combinedContents(for layer: SandboxfileSettingsLayer) -> String {
    let layerSources = sources(for: layer)
    guard !layerSources.isEmpty else { return "" }
    if layerSources.count == 1 {
      return layerSources[0].contents
    }

    return layerSources.map { source in
      "# \(source.path)\n\n\(source.contents.trimmingCharacters(in: .newlines))"
    }
    .joined(separator: "\n\n")
      + "\n"
  }
}

enum SandboxfileSettingsSnapshotLoader {
  static func load(rootPath: String) throws -> SandboxfileSettingsSnapshot {
    let paths = try ArgonCLI.sandboxConfigPaths(repoRoot: rootPath)
    let sources = try paths.existingPaths.enumerated().map { index, path in
      let contents = try String(contentsOfFile: path, encoding: .utf8)
      return makeSource(
        order: index + 1,
        path: path,
        rootPath: rootPath,
        contents: contents
      )
    }

    let projectSources = sources.filter { !isUserSource(path: $0.path) }
    let userSources = sources.filter { isUserSource(path: $0.path) }
    return SandboxfileSettingsSnapshot(
      rootPath: rootPath,
      initPath: paths.initPath,
      projectSources: projectSources,
      userSources: userSources
    )
  }

  static func makeSource(
    order: Int,
    path: String,
    rootPath: String,
    contents: String,
    homePath: String = NSHomeDirectory()
  ) -> SandboxfileSettingsSource {
    let url = URL(fileURLWithPath: path)
    let title = url.lastPathComponent
    let parentPath = url.deletingLastPathComponent().path

    return SandboxfileSettingsSource(
      order: order,
      path: path,
      title: title,
      subtitle: subtitle(forParentPath: parentPath, rootPath: rootPath, homePath: homePath),
      contents: contents
    )
  }

  static func subtitle(
    forParentPath parentPath: String,
    rootPath: String,
    homePath: String = NSHomeDirectory()
  ) -> String {
    if parentPath == rootPath {
      return "focused root"
    }
    if parentPath == homePath {
      return "~"
    }
    if parentPath.hasPrefix(rootPath + "/") {
      return String(parentPath.dropFirst(rootPath.count + 1))
    }
    if parentPath.hasPrefix(homePath + "/") {
      return "~/" + String(parentPath.dropFirst(homePath.count + 1))
    }
    return parentPath
  }

  static func isUserSource(
    path: String,
    homePath: String = NSHomeDirectory()
  ) -> Bool {
    URL(fileURLWithPath: path).deletingLastPathComponent().path == homePath
  }
}
