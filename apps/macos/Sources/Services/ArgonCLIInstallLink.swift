import AppKit
import Foundation

struct ArgonCLIInstallLinkStatus: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case installed
    case missing
    case pointsElsewhere(currentTarget: String)
    case occupiedByFile
    case bundledCLIUnavailable
  }

  let linkPath: String
  let expectedTargetPath: String?
  let state: State

  var title: String {
    switch state {
    case .installed:
      return "Linked"
    case .missing:
      return "Missing"
    case .pointsElsewhere:
      return "Needs relink"
    case .occupiedByFile:
      return "Needs relink"
    case .bundledCLIUnavailable:
      return "Bundled CLI unavailable"
    }
  }

  var detail: String {
    let usage =
      "It enables `argon <dir>` to open Argon in a directory and `argon review <dir>` to open the review UI from Terminal, editors, and scripts."

    switch state {
    case .installed:
      return "Argon’s command line tool is installed."
    case .missing:
      return "Argon’s command line tool is not installed. \(usage)"
    case .pointsElsewhere:
      return "Argon’s command line tool needs to be fixed. \(usage)"
    case .occupiedByFile:
      return "Argon’s command line tool needs to be fixed. \(usage)"
    case .bundledCLIUnavailable:
      return
        "This app bundle does not include `Resources/bin/argon`, so Argon cannot install the link."
    }
  }

  var symbolName: String {
    switch state {
    case .installed:
      return "checkmark.circle.fill"
    case .missing, .pointsElsewhere, .occupiedByFile:
      return "exclamationmark.triangle.fill"
    case .bundledCLIUnavailable:
      return "xmark.octagon.fill"
    }
  }

  var canRepair: Bool {
    guard expectedTargetPath != nil else { return false }
    switch state {
    case .installed:
      return false
    case .missing, .pointsElsewhere, .occupiedByFile:
      return true
    case .bundledCLIUnavailable:
      return false
    }
  }

  var isHealthy: Bool {
    if case .installed = state {
      return true
    }
    return false
  }

  var repairButtonTitle: String {
    switch state {
    case .missing:
      return "Install"
    case .pointsElsewhere, .occupiedByFile:
      return "Repair"
    case .installed:
      return "Installed"
    case .bundledCLIUnavailable:
      return "Unavailable"
    }
  }
}

enum ArgonCLIInstallLinkError: LocalizedError {
  case bundledCLIUnavailable
  case refusingToReplaceDirectory(String)
  case authorizationFailed(String)
  case verificationFailed

  var errorDescription: String? {
    switch self {
    case .bundledCLIUnavailable:
      return "Argon could not find its bundled CLI binary."
    case .refusingToReplaceDirectory(let path):
      return "Refusing to replace directory at \(path). Remove it manually first."
    case .authorizationFailed(let message):
      return message
    case .verificationFailed:
      return "Argon updated the link, but the installed target still did not match the bundled CLI."
    }
  }
}

enum ArgonCLIInstallLink {
  struct Paths: Equatable, Sendable {
    let linkPath: String
    let targetPath: String?
  }

  typealias AuthorizedShellRunner = @MainActor @Sendable (String) throws -> Void

  static func resolvedPaths() -> Paths {
    Paths(linkPath: "/usr/local/bin/argon", targetPath: ArgonCLI.bundledCLIPath())
  }

  static func status(
    paths: Paths = resolvedPaths(),
    fileManager: FileManager = .default
  ) -> ArgonCLIInstallLinkStatus {
    guard let expectedTargetPath = paths.targetPath,
      fileManager.fileExists(atPath: expectedTargetPath),
      fileManager.isExecutableFile(atPath: expectedTargetPath)
    else {
      return ArgonCLIInstallLinkStatus(
        linkPath: paths.linkPath,
        expectedTargetPath: paths.targetPath,
        state: .bundledCLIUnavailable
      )
    }

    if let currentTarget = currentSymlinkTarget(atPath: paths.linkPath, fileManager: fileManager) {
      if canonicalPath(currentTarget, fileManager: fileManager)
        == canonicalPath(expectedTargetPath, fileManager: fileManager)
      {
        return ArgonCLIInstallLinkStatus(
          linkPath: paths.linkPath,
          expectedTargetPath: expectedTargetPath,
          state: .installed
        )
      }

      return ArgonCLIInstallLinkStatus(
        linkPath: paths.linkPath,
        expectedTargetPath: expectedTargetPath,
        state: .pointsElsewhere(currentTarget: currentTarget)
      )
    }

    if fileManager.fileExists(atPath: paths.linkPath) {
      return ArgonCLIInstallLinkStatus(
        linkPath: paths.linkPath,
        expectedTargetPath: expectedTargetPath,
        state: .occupiedByFile
      )
    }

    return ArgonCLIInstallLinkStatus(
      linkPath: paths.linkPath,
      expectedTargetPath: expectedTargetPath,
      state: .missing
    )
  }

  @MainActor
  static func repair(
    paths: Paths = resolvedPaths(),
    fileManager: FileManager = .default,
    authorizedShellRunner: AuthorizedShellRunner? = nil
  ) throws -> ArgonCLIInstallLinkStatus {
    guard let targetPath = paths.targetPath,
      fileManager.fileExists(atPath: targetPath),
      fileManager.isExecutableFile(atPath: targetPath)
    else {
      throw ArgonCLIInstallLinkError.bundledCLIUnavailable
    }

    do {
      try installLink(paths: paths, fileManager: fileManager)
    } catch {
      if shouldRetryWithAuthorization(error) {
        try (authorizedShellRunner ?? defaultAuthorizedShellRunner)(
          authorizedShellCommand(linkPath: paths.linkPath, targetPath: targetPath)
        )
      } else {
        throw error
      }
    }

    let currentStatus = status(paths: paths, fileManager: fileManager)
    if currentStatus.state != .installed {
      throw ArgonCLIInstallLinkError.verificationFailed
    }
    return currentStatus
  }

  private static func installLink(paths: Paths, fileManager: FileManager) throws {
    guard let targetPath = paths.targetPath else {
      throw ArgonCLIInstallLinkError.bundledCLIUnavailable
    }

    let linkURL = URL(fileURLWithPath: paths.linkPath)
    let parentURL = linkURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

    var isDirectory = ObjCBool(false)
    if fileManager.fileExists(atPath: paths.linkPath, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      throw ArgonCLIInstallLinkError.refusingToReplaceDirectory(paths.linkPath)
    }

    if currentSymlinkTarget(atPath: paths.linkPath, fileManager: fileManager) != nil
      || fileManager.fileExists(atPath: paths.linkPath)
    {
      try fileManager.removeItem(atPath: paths.linkPath)
    }

    try fileManager.createSymbolicLink(atPath: paths.linkPath, withDestinationPath: targetPath)
  }

  private static func currentSymlinkTarget(atPath path: String, fileManager: FileManager) -> String?
  {
    guard let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
      return nil
    }
    if rawTarget.hasPrefix("/") {
      return URL(fileURLWithPath: rawTarget).standardizedFileURL.path
    }
    let baseURL = URL(fileURLWithPath: path).deletingLastPathComponent()
    return baseURL.appendingPathComponent(rawTarget).standardizedFileURL.path
  }

  private static func canonicalPath(_ path: String, fileManager: FileManager) -> String {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    if fileManager.fileExists(atPath: standardized) {
      return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().standardizedFileURL.path
    }
    return standardized
  }

  private static func shouldRetryWithAuthorization(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain,
      [NSFileWriteNoPermissionError, NSFileWriteUnknownError].contains(nsError.code)
    {
      return true
    }

    if nsError.domain == NSPOSIXErrorDomain,
      [Int(EACCES), Int(EPERM)].contains(nsError.code)
    {
      return true
    }

    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain,
      [Int(EACCES), Int(EPERM)].contains(underlying.code)
    {
      return true
    }

    return false
  }

  private static func authorizedShellCommand(linkPath: String, targetPath: String) -> String {
    let parentPath = URL(fileURLWithPath: linkPath).deletingLastPathComponent().path
    return [
      "/bin/mkdir -p \(quotedForShell(parentPath))",
      "if [ -d \(quotedForShell(linkPath)) ]; then echo 'Refusing to replace directory at \(linkPath)' >&2; exit 1; fi",
      "/bin/rm -f \(quotedForShell(linkPath))",
      "/bin/ln -s \(quotedForShell(targetPath)) \(quotedForShell(linkPath))",
    ].joined(separator: " && ")
  }

  @MainActor
  private static func defaultAuthorizedShellRunner(command: String) throws {
    let scriptSource =
      "do shell script \"\(escapeForAppleScript(command))\" with administrator privileges"
    guard let script = NSAppleScript(source: scriptSource) else {
      throw ArgonCLIInstallLinkError.authorizationFailed(
        "Argon could not prepare the installer script."
      )
    }

    var error: NSDictionary?
    script.executeAndReturnError(&error)
    if let error {
      let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown authorization error"
      throw ArgonCLIInstallLinkError.authorizationFailed(message)
    }
  }

  private static func quotedForShell(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private static func escapeForAppleScript(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
