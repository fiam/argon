import Foundation

struct ResolvedTarget {
  let mode: ReviewMode
  let baseRef: String
  let headRef: String
  let mergeBaseSha: String
}

enum GitService {
  private static let emptyTreeSHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  // MARK: - Diff Fingerprint (lightweight check for changes)

  /// Returns a string that changes when the working tree changes.
  /// Uses git diff --stat for tracked changes and file sizes for untracked files.
  static func diffFingerprint(
    repoRoot: String, mode: ReviewMode, baseRef: String, headRef: String, mergeBaseSha: String
  ) -> String {
    // Tracked changes stat
    var args = ["-C", repoRoot, "diff", "--stat", "--no-color"]
    switch mode {
    case .branch:
      args.append(mergeBaseSha)
      if let currentHead = resolveRef(repoRoot: repoRoot, ref: "HEAD"),
        let targetHead = resolveRef(repoRoot: repoRoot, ref: headRef),
        currentHead != targetHead
      {
        args.append(headRef)
      }
    case .commit:
      args.append(baseRef)
      args.append(headRef)
    case .uncommitted:
      args.append("HEAD")
    }
    var result = runGit(args)

    // Untracked files with sizes (so content changes are detected)
    let shouldIncludeUntracked = mode != .commit
    let untrackedList = shouldIncludeUntracked ? untrackedFiles(repoRoot: repoRoot) : []
    if !untrackedList.isEmpty {
      result += "\n__untracked__"
      let fm = FileManager.default
      for file in untrackedList {
        let fullPath = (repoRoot as NSString).appendingPathComponent(file)
        let size = (try? fm.attributesOfItem(atPath: fullPath)[.size] as? Int) ?? 0
        result += "\n\(file):\(size)"
      }
    }

    return result
  }

  // MARK: - Diff

  static func diff(
    repoRoot: String, mode: ReviewMode, baseRef: String, headRef: String, mergeBaseSha: String
  ) -> String {
    var args = ["-C", repoRoot, "diff", "--no-color", "--unified=3", "--no-ext-diff"]

    switch mode {
    case .branch:
      args.append(mergeBaseSha)
      if let currentHead = resolveRef(repoRoot: repoRoot, ref: "HEAD"),
        let targetHead = resolveRef(repoRoot: repoRoot, ref: headRef),
        currentHead != targetHead
      {
        args.append(headRef)
      }
    case .commit:
      args.append(baseRef)
      args.append(headRef)
    case .uncommitted:
      args.append("HEAD")
    }

    var result = runGit(args)

    // Append untracked (non-ignored) files as diffs against /dev/null
    let untrackedFiles = mode == .commit ? [] : untrackedFiles(repoRoot: repoRoot)
    for file in untrackedFiles {
      let fileDiff = runGit([
        "-C", repoRoot, "diff", "--no-color", "--unified=3", "--no-ext-diff",
        "--no-index", "/dev/null", file,
      ])
      if !fileDiff.isEmpty {
        result += "\n" + fileDiff
      }
    }

    return result
  }

  /// Returns untracked, non-ignored files relative to the repo root.
  private static func untrackedFiles(repoRoot: String) -> [String] {
    let output = runGit([
      "-C", repoRoot, "ls-files", "--others", "--exclude-standard",
    ])
    return
      output
      .split(separator: "\n")
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  static func diff(session: ReviewSession) -> String {
    diff(
      repoRoot: session.repoRoot, mode: session.mode,
      baseRef: session.baseRef, headRef: session.headRef,
      mergeBaseSha: session.mergeBaseSha)
  }

  static func contextSources(
    for files: [FileDiff],
    repoRoot: String,
    mode: ReviewMode,
    baseRef: String,
    headRef: String,
    mergeBaseSha: String
  ) -> [String: DiffContextSource] {
    var result: [String: DiffContextSource] = [:]
    let isHeadCheckedOut: Bool =
      if mode == .branch,
        let currentHead = resolveRef(repoRoot: repoRoot, ref: "HEAD"),
        let targetHead = resolveRef(repoRoot: repoRoot, ref: headRef)
      {
        currentHead == targetHead
      } else {
        false
      }

    for file in files {
      if let source = contextSource(
        for: file,
        repoRoot: repoRoot,
        mode: mode,
        baseRef: baseRef,
        headRef: headRef,
        mergeBaseSha: mergeBaseSha,
        isHeadCheckedOut: isHeadCheckedOut
      ) {
        result[file.id] = source
      }
    }

    return result
  }

  // MARK: - Target Detection

  /// Auto-detect the best review mode for the repo.
  static func autoDetectTarget(repoRoot: String) -> ResolvedTarget? {
    if isHeadDetached(repoRoot: repoRoot) {
      return resolveCommitTarget(repoRoot: repoRoot)
    }

    guard let currentBranch = currentBranchName(repoRoot: repoRoot),
      let baseRef = inferBaseRef(repoRoot: repoRoot)
    else {
      // Can't determine branch info — fall back to uncommitted
      return resolveUncommittedTarget(repoRoot: repoRoot)
    }

    let shortBase = baseRef.hasPrefix("origin/") ? String(baseRef.dropFirst(7)) : baseRef
    if shortBase == currentBranch {
      // On the base branch itself — uncommitted makes more sense
      return resolveUncommittedTarget(repoRoot: repoRoot)
    }

    // On a feature branch — use branch mode
    return resolveBranchTarget(repoRoot: repoRoot, baseRef: baseRef, headRef: currentBranch)
  }

  static func resolveBranchTarget(repoRoot: String, baseRef: String, headRef: String)
    -> ResolvedTarget?
  {
    guard let mergeBase = mergeBase(repoRoot: repoRoot, a: baseRef, b: headRef) else { return nil }
    return ResolvedTarget(
      mode: .branch, baseRef: baseRef, headRef: headRef, mergeBaseSha: mergeBase)
  }

  static func resolveCommitTarget(repoRoot: String, commitRef: String = "HEAD") -> ResolvedTarget? {
    guard let sha = resolveRef(repoRoot: repoRoot, ref: commitRef),
      let base = parentCommitOrEmptyTree(repoRoot: repoRoot, commitSHA: sha)
    else { return nil }
    return ResolvedTarget(mode: .commit, baseRef: base, headRef: sha, mergeBaseSha: sha)
  }

  static func resolveUncommittedTarget(repoRoot: String) -> ResolvedTarget? {
    guard let sha = resolveRef(repoRoot: repoRoot, ref: "HEAD") else { return nil }
    return ResolvedTarget(
      mode: .uncommitted, baseRef: "HEAD", headRef: "WORKTREE", mergeBaseSha: sha)
  }

  // MARK: - Git Helpers

  static func currentBranchName(repoRoot: String) -> String? {
    let output = runGit(["-C", repoRoot, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    if output.isEmpty || output == "HEAD" { return nil }
    return output
  }

  static func inferBaseRef(repoRoot: String) -> String? {
    // Try origin/HEAD
    let originHead = runGit([
      "-C", repoRoot, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    if !originHead.isEmpty { return originHead }

    for candidate in ["origin/main", "main", "origin/master", "master"] {
      if resolveRef(repoRoot: repoRoot, ref: candidate) != nil {
        return candidate
      }
    }
    return nil
  }

  private static func isHeadDetached(repoRoot: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repoRoot, "symbolic-ref", "--quiet", "--short", "HEAD"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus != 0
    } catch {
      return true
    }
  }

  private static func mergeBase(repoRoot: String, a: String, b: String) -> String? {
    let output = runGit(["-C", repoRoot, "merge-base", a, b]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
  }

  private static func parentCommitOrEmptyTree(repoRoot: String, commitSHA: String) -> String? {
    let output = runGit(["-C", repoRoot, "rev-parse", "--verify", "\(commitSHA)^"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? emptyTreeSHA : output
  }

  static func resolveRef(repoRoot: String, ref: String) -> String? {
    let output = runGit(["-C", repoRoot, "rev-parse", "--verify", "\(ref)^{commit}"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
  }

  private static func contextSource(
    for file: FileDiff,
    repoRoot: String,
    mode: ReviewMode,
    baseRef: String,
    headRef: String,
    mergeBaseSha: String,
    isHeadCheckedOut: Bool
  ) -> DiffContextSource? {
    if file.newPath != "/dev/null",
      let lines = newSideContextLines(
        repoRoot: repoRoot,
        filePath: file.newPath,
        mode: mode,
        headRef: headRef,
        isHeadCheckedOut: isHeadCheckedOut
      )
    {
      return DiffContextSource(side: .new, lines: lines)
    }

    if file.oldPath != "/dev/null",
      let lines = oldSideContextLines(
        repoRoot: repoRoot,
        filePath: file.oldPath,
        mode: mode,
        baseRef: baseRef,
        mergeBaseSha: mergeBaseSha
      )
    {
      return DiffContextSource(side: .old, lines: lines)
    }

    return nil
  }

  private static func newSideContextLines(
    repoRoot: String,
    filePath: String,
    mode: ReviewMode,
    headRef: String,
    isHeadCheckedOut: Bool
  ) -> [String]? {
    switch mode {
    case .uncommitted:
      workingTreeLines(repoRoot: repoRoot, filePath: filePath)
    case .branch:
      if isHeadCheckedOut {
        workingTreeLines(repoRoot: repoRoot, filePath: filePath)
      } else {
        blobLines(repoRoot: repoRoot, ref: headRef, filePath: filePath)
      }
    case .commit:
      blobLines(repoRoot: repoRoot, ref: headRef, filePath: filePath)
    }
  }

  private static func oldSideContextLines(
    repoRoot: String,
    filePath: String,
    mode: ReviewMode,
    baseRef: String,
    mergeBaseSha: String
  ) -> [String]? {
    let ref: String =
      switch mode {
      case .branch:
        mergeBaseSha
      case .commit:
        baseRef
      case .uncommitted:
        "HEAD"
      }

    return blobLines(repoRoot: repoRoot, ref: ref, filePath: filePath)
  }

  private static func workingTreeLines(repoRoot: String, filePath: String) -> [String]? {
    let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(filePath)
    guard let data = try? Data(contentsOf: url),
      let contents = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return splitLines(contents)
  }

  private static func blobLines(repoRoot: String, ref: String, filePath: String) -> [String]? {
    let contents = runGit(["-C", repoRoot, "show", "\(ref):\(filePath)"])
    guard !contents.isEmpty else { return nil }
    return splitLines(contents)
  }

  private static func splitLines(_ text: String) -> [String] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if text.hasSuffix("\n"), !lines.isEmpty {
      lines.removeLast()
    }
    return lines
  }

  static func runGit(_ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return ""
    }

    // Read stdout before waitUntilExit to avoid deadlock when
    // output exceeds the pipe buffer (~64KB).
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
  }
}
