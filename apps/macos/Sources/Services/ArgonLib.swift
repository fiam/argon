import Darwin
import Foundation

enum ArgonLib {
  static let shellStartupPathResolvedEnvironmentKey = "ARGON_SHELL_STARTUP_PATH_RESOLVED"

  enum ArgonLibError: LocalizedError {
    case operationFailed(String)

    var errorDescription: String? {
      switch self {
      case .operationFailed(let message):
        message
      }
    }
  }

  static func resolveInteractivePath(
    environment: [String: String],
    timeoutMilliseconds: UInt64 = 2_000
  ) -> String? {
    var allocatedStrings: [UnsafeMutablePointer<CChar>] = []
    var entries: [ArgonEnvironmentEntry] = []
    for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
      guard let keyPointer = strdup(key) else {
        for pointer in allocatedStrings {
          free(pointer)
        }
        return nil
      }
      allocatedStrings.append(keyPointer)

      guard let valuePointer = strdup(value) else {
        for pointer in allocatedStrings {
          free(pointer)
        }
        return nil
      }
      allocatedStrings.append(valuePointer)
      entries.append(
        ArgonEnvironmentEntry(
          key: UnsafePointer(keyPointer),
          value: UnsafePointer(valuePointer)
        ))
    }
    defer {
      for pointer in allocatedStrings {
        free(pointer)
      }
    }

    return entries.withUnsafeBufferPointer { buffer in
      guard
        let rawPath = argonlib_resolve_interactive_path(
          buffer.baseAddress,
          buffer.count,
          timeoutMilliseconds
        )
      else {
        return nil
      }
      defer { argonlib_string_free(rawPath) }
      return String(cString: rawPath)
    }
  }

  static func highlightedText(
    text: String,
    path: String,
    theme: String
  ) throws -> [[StyledSpan]] {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let response = text.withCString { textPointer in
      path.withCString { pathPointer in
        theme.withCString { themePointer in
          argonlib_highlight_text(
            textPointer,
            pathPointer,
            themePointer,
            &errorPointer
          )
        }
      }
    }

    guard let response else {
      throw makeError(errorPointer, fallback: "Failed to highlight text")
    }
    defer { argonlib_highlighted_text_free(response) }

    return makeArray(response.pointee.lines, count: response.pointee.line_count) { line in
      makeSpans(line.spans, count: line.span_count)
    }
  }

  static func highlightedDiff(
    sessionId: String,
    repoRoot: String,
    theme: String
  ) throws -> [FileDiff] {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let response = repoRoot.withCString { repoRootPointer in
      sessionId.withCString { sessionIdPointer in
        theme.withCString { themePointer in
          argonlib_highlight_diff_for_session(
            repoRootPointer,
            sessionIdPointer,
            themePointer,
            &errorPointer
          )
        }
      }
    }

    guard let response else {
      throw makeError(errorPointer, fallback: "Failed to highlight diff")
    }
    defer { argonlib_highlighted_diff_free(response) }

    return makeArray(response.pointee.files, count: response.pointee.file_count, makeFile)
  }

  private static func makeFile(_ file: ArgonHighlightedFile) -> FileDiff {
    let hunks = makeArray(file.unified_hunks, count: file.unified_hunk_count) { hunk in
      DiffHunk(
        header: string(from: hunk.header),
        oldStart: hunk.old_start,
        oldLineCount: hunk.old_line_count,
        newStart: hunk.new_start,
        newLineCount: hunk.new_line_count,
        lines: makeArray(hunk.lines, count: hunk.line_count, makeLine)
      )
    }
    let sideBySide = makeArray(file.side_by_side, count: file.side_by_side_count) { pair in
      SideBySidePair(
        left: makeOptionalLine(pair.left),
        right: makeOptionalLine(pair.right)
      )
    }

    return FileDiff(
      oldPath: string(from: file.old_path),
      newPath: string(from: file.new_path),
      hunks: hunks,
      sideBySide: sideBySide,
      addedCount: Int(file.added_count),
      removedCount: Int(file.removed_count)
    )
  }

  private static func makeOptionalLine(_ pointer: UnsafeMutablePointer<ArgonHighlightedLine>?)
    -> DiffLine?
  {
    pointer.map { makeLine($0.pointee) }
  }

  private static func makeLine(_ line: ArgonHighlightedLine) -> DiffLine {
    DiffLine(
      kind: makeLineKind(line.kind),
      spans: makeSpans(line.spans, count: line.span_count),
      oldLine: line.old_line_present ? line.old_line : nil,
      newLine: line.new_line_present ? line.new_line : nil
    )
  }

  private static func makeSpans(
    _ pointer: UnsafeMutablePointer<ArgonStyledSpan>?,
    count: Int
  ) -> [StyledSpan] {
    makeArray(pointer, count: count) { span in
      StyledSpan(
        text: string(from: span.text),
        fg: optionalString(from: span.fg),
        bold: span.bold,
        italic: span.italic,
        changed: span.changed
      )
    }
  }

  private static func makeLineKind(_ kind: UInt32) -> DiffLineKind {
    switch kind {
    case 1:
      .added
    case 2:
      .removed
    default:
      .context
    }
  }

  private static func makeArray<Element, Result>(
    _ pointer: UnsafeMutablePointer<Element>?,
    count: Int,
    _ transform: (Element) -> Result
  ) -> [Result] {
    guard let pointer, count > 0 else { return [] }
    return UnsafeBufferPointer(start: UnsafePointer(pointer), count: count).map(transform)
  }

  private static func makeArray<Element, Result>(
    _ pointer: UnsafeMutablePointer<Element>?,
    count: UInt,
    _ transform: (Element) -> Result
  ) -> [Result] {
    makeArray(pointer, count: Int(count), transform)
  }

  private static func string(from pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
  }

  private static func optionalString(from pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
  }

  private static func makeError(
    _ errorPointer: UnsafeMutablePointer<CChar>?,
    fallback: String
  ) -> ArgonLibError {
    guard let errorPointer else {
      return .operationFailed(fallback)
    }

    let message = String(cString: errorPointer)
    argonlib_string_free(errorPointer)
    return .operationFailed(message.isEmpty ? fallback : message)
  }
}
