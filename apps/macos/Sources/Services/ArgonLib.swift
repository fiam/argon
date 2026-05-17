import Darwin
import Foundation

enum ArgonLib {
  static let shellStartupPathResolvedEnvironmentKey = "ARGON_SHELL_STARTUP_PATH_RESOLVED"

  struct WorkspaceMergeability: Sendable {
    let status: WorkspaceMergeabilityStatus
    let baseRef: String?
    let headRef: String?
    let mergeBaseSha: String?
    let topology: WorkspaceBranchTopology?
    let detail: String?
  }

  enum WorkspaceMergeabilityStatus: Sendable {
    case unknown
    case clean
    case conflicted
  }

  struct WorkspaceBranchTopology: Equatable, Sendable {
    let aheadCount: Int
    let behindCount: Int
  }

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

  static func highlightedDiff(
    repoRoot: String,
    mode: ReviewMode,
    baseRef: String,
    headRef: String,
    mergeBaseSha: String,
    theme: String
  ) throws -> [FileDiff] {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let response = repoRoot.withCString { repoRootPointer in
      mode.rawValue.withCString { modePointer in
        baseRef.withCString { baseRefPointer in
          headRef.withCString { headRefPointer in
            mergeBaseSha.withCString { mergeBaseShaPointer in
              theme.withCString { themePointer in
                argonlib_highlight_diff_for_target(
                  repoRootPointer,
                  modePointer,
                  baseRefPointer,
                  headRefPointer,
                  mergeBaseShaPointer,
                  themePointer,
                  &errorPointer
                )
              }
            }
          }
        }
      }
    }

    guard let response else {
      throw makeError(errorPointer, fallback: "Failed to highlight diff")
    }
    defer { argonlib_highlighted_diff_free(response) }

    return makeArray(response.pointee.files, count: response.pointee.file_count, makeFile)
  }

  static func diff(
    repoRoot: String,
    mode: ReviewMode,
    baseRef: String,
    headRef: String,
    mergeBaseSha: String
  ) throws -> [FileDiff] {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let response = repoRoot.withCString { repoRootPointer in
      mode.rawValue.withCString { modePointer in
        baseRef.withCString { baseRefPointer in
          headRef.withCString { headRefPointer in
            mergeBaseSha.withCString { mergeBaseShaPointer in
              argonlib_build_diff(
                repoRootPointer,
                modePointer,
                baseRefPointer,
                headRefPointer,
                mergeBaseShaPointer,
                &errorPointer
              )
            }
          }
        }
      }
    }

    guard let response else {
      throw makeError(errorPointer, fallback: "Failed to build diff")
    }
    defer { argonlib_diff_free(response) }

    return makeArray(response.pointee.files, count: response.pointee.file_count, makeFile)
  }

  static func diffFingerprint(
    repoRoot: String,
    mode: ReviewMode,
    headRef: String,
    mergeBaseSha: String
  ) throws -> String {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let response = repoRoot.withCString { repoRootPointer in
      mode.rawValue.withCString { modePointer in
        headRef.withCString { headRefPointer in
          mergeBaseSha.withCString { mergeBaseShaPointer in
            argonlib_diff_fingerprint(
              repoRootPointer,
              modePointer,
              headRefPointer,
              mergeBaseShaPointer,
              &errorPointer
            )
          }
        }
      }
    }

    guard let response else {
      throw makeError(errorPointer, fallback: "Failed to build diff fingerprint")
    }
    defer { argonlib_string_free(response) }

    return String(cString: response)
  }

  static func workspaceMergeability(
    repoRoot: String,
    baseRef: String? = nil,
    headRef: String? = nil
  ) throws -> WorkspaceMergeability {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let response = repoRoot.withCString { repoRootPointer in
      withOptionalCString(baseRef) { baseRefPointer in
        withOptionalCString(headRef) { headRefPointer in
          argonlib_workspace_mergeability(
            repoRootPointer,
            baseRefPointer,
            headRefPointer,
            &errorPointer
          )
        }
      }
    }

    guard let response else {
      throw makeError(errorPointer, fallback: "Failed to inspect workspace mergeability")
    }
    defer { argonlib_workspace_mergeability_free(response) }

    return makeWorkspaceMergeability(response.pointee)
  }

  private static func makeWorkspaceMergeability(
    _ mergeability: ArgonWorkspaceMergeability
  ) -> WorkspaceMergeability {
    WorkspaceMergeability(
      status: makeWorkspaceMergeabilityStatus(mergeability.status),
      baseRef: optionalString(from: mergeability.base_ref),
      headRef: optionalString(from: mergeability.head_ref),
      mergeBaseSha: optionalString(from: mergeability.merge_base_sha),
      topology: mergeability.topology_present
        ? WorkspaceBranchTopology(
          aheadCount: Int(mergeability.topology.ahead_count),
          behindCount: Int(mergeability.topology.behind_count)
        ) : nil,
      detail: optionalString(from: mergeability.detail)
    )
  }

  private static func makeWorkspaceMergeabilityStatus(
    _ status: UInt32
  ) -> WorkspaceMergeabilityStatus {
    switch status {
    case UInt32(ARGON_MERGEABILITY_STATUS_CLEAN):
      .clean
    case UInt32(ARGON_MERGEABILITY_STATUS_CONFLICTED):
      .conflicted
    default:
      .unknown
    }
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

  private static func makeFile(_ file: ArgonDiffFile) -> FileDiff {
    FileDiff(
      oldPath: string(from: file.old_path),
      newPath: string(from: file.new_path),
      hunks: makeArray(file.hunks, count: file.hunk_count) { hunk in
        DiffHunk(
          header: string(from: hunk.header),
          oldStart: hunk.old_start,
          oldLineCount: hunk.old_line_count,
          newStart: hunk.new_start,
          newLineCount: hunk.new_line_count,
          lines: makeArray(hunk.lines, count: hunk.line_count, makeLine)
        )
      },
      addedCount: Int(file.added_count),
      removedCount: Int(file.removed_count)
    )
  }

  private static func makeLine(_ line: ArgonDiffLine) -> DiffLine {
    DiffLine(
      kind: makeLineKind(line.kind),
      content: string(from: line.content),
      oldLine: line.old_line_present ? line.old_line : nil,
      newLine: line.new_line_present ? line.new_line : nil
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

  private static func withOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) -> Result
  ) -> Result {
    guard let value else {
      return body(nil)
    }
    return value.withCString(body)
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
