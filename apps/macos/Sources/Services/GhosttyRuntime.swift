import Darwin
import Foundation
import GhosttyKit

enum GhosttyRuntimeError: Error {
  case initializationFailed
}

enum GhosttyRuntime {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var initialized = false

  static func ensureInitialized(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) throws {
    lock.lock()
    defer { lock.unlock() }

    if initialized {
      return
    }

    if let resourcesPath = preferredResourcesPath(
      environment: environment,
      bundle: bundle,
      fileManager: fileManager
    ) {
      setenv("GHOSTTY_RESOURCES_DIR", resourcesPath, 1)
    }

    let arguments = [bundle.executablePath ?? bundle.bundlePath]
    guard
      withCStringArguments(
        arguments,
        body: { argc, argv in
          ghostty_init(UInt(argc), argv)
        }) == GHOSTTY_SUCCESS
    else {
      throw GhosttyRuntimeError.initializationFailed
    }

    AppSignalHandling.installEmbeddedTerminalHandlers()
    initialized = true
  }

  static func preferredResourcesPath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> String? {
    if let path = environment["GHOSTTY_RESOURCES_DIR"],
      !path.isEmpty,
      fileManager.fileExists(atPath: path)
    {
      return path
    }

    if let path = bundle.object(forInfoDictionaryKey: "ArgonGhosttyResourcesPath") as? String,
      !path.isEmpty,
      !path.contains("$("),
      fileManager.fileExists(atPath: path)
    {
      return path
    }

    if let resourcePath = bundle.resourceURL?.appendingPathComponent("ghostty").path,
      fileManager.fileExists(atPath: resourcePath)
    {
      return resourcePath
    }

    return nil
  }

  private static func withCStringArguments<Result>(
    _ arguments: [String],
    body: (_ argc: Int, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
  ) -> Result {
    let cStrings = arguments.map { strdup($0) }
    defer {
      for pointer in cStrings {
        free(pointer)
      }
    }

    var argv = cStrings + [nil]
    return argv.withUnsafeMutableBufferPointer { buffer in
      body(arguments.count, buffer.baseAddress!)
    }
  }
}
