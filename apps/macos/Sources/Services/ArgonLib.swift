import Foundation

enum ArgonLib {
  static let shellStartupPathResolvedEnvironmentKey = "ARGON_SHELL_STARTUP_PATH_RESOLVED"

  static func resolveInteractivePath(
    environment: [String: String],
    timeoutMilliseconds: UInt64 = 2_000
  ) -> String? {
    guard
      let data = try? JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    return json.withCString { environmentJSON in
      guard
        let rawPath = argonlib_resolve_interactive_path_json(
          environmentJSON,
          timeoutMilliseconds
        )
      else {
        return nil
      }
      defer { argonlib_string_free(rawPath) }
      return String(cString: rawPath)
    }
  }
}
