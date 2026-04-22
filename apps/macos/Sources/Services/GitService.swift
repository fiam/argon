import Foundation

struct ResolvedTarget: Sendable {
  let mode: ReviewMode
  let baseRef: String
  let headRef: String
  let mergeBaseSha: String
}

struct BranchTopology: Hashable, Sendable {
  let aheadCount: Int
  let behindCount: Int

  var needsRebase: Bool {
    behindCount > 0
  }

  var canFastForwardBase: Bool {
    aheadCount > 0 && behindCount == 0
  }
}

struct DiscoveredWorktree: Identifiable, Hashable, Sendable {
  var id: String { path }

  let path: String
  let branchName: String?
  let headSHA: String?
  let isBaseWorktree: Bool
  let isDetached: Bool
}

struct WorktreeDiffSummary: Hashable, Sendable {
  static let empty = WorktreeDiffSummary(fileCount: 0, addedLineCount: 0, removedLineCount: 0)

  let fileCount: Int
  let addedLineCount: Int
  let removedLineCount: Int

  var hasChanges: Bool {
    fileCount > 0 || addedLineCount > 0 || removedLineCount > 0
  }
}

enum GitService {
  private static let emptyTreeSHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  nonisolated(unsafe) static var commandRunner:
    (
      @Sendable (
        _ executable: String, _ arguments: [String], _ currentDirectoryPath: String?,
        _ environment: [String: String]?
      ) -> CommandResult
    )?

  enum GitError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
      switch self {
      case .commandFailed(let message):
        return message
      }
    }
  }

  // MARK: - Workspace

  static func resolveWorkspaceTarget(path: String) throws -> WorkspaceTarget {
    let selectedWorktreePath = try requireGit([
      "-C", path,
      "rev-parse", "--show-toplevel",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    let repoCommonDir = try requireGit([
      "-C", path,
      "rev-parse", "--path-format=absolute", "--git-common-dir",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)

    guard !selectedWorktreePath.isEmpty else {
      throw GitError.commandFailed("Could not resolve the current worktree.")
    }
    guard !repoCommonDir.isEmpty else {
      throw GitError.commandFailed("Could not resolve the shared Git common directory.")
    }

    let repoRoot = baseWorktreePath(repoCommonDir: repoCommonDir) ?? selectedWorktreePath
    let normalizedRepoRoot = normalizePath(repoRoot)
    let normalizedSelectedWorktreePath = normalizePath(selectedWorktreePath)
    return WorkspaceTarget(
      repoRoot: normalizedRepoRoot,
      repoCommonDir: normalizePath(repoCommonDir),
      selectedWorktreePath: normalizedSelectedWorktreePath,
      showsLinkedWorktreeWarning: normalizedRepoRoot != normalizedSelectedWorktreePath
    )
  }

  static func discoverWorktrees(repoRoot: String, repoCommonDir: String) throws
    -> [DiscoveredWorktree]
  {
    let output = try requireGit([
      "-C", repoRoot,
      "worktree", "list", "--porcelain",
    ])
    return parseWorktreeList(
      output,
      baseWorktreePath: baseWorktreePath(repoCommonDir: repoCommonDir) ?? repoRoot
    )
  }

  static func createWorktree(
    repoRoot: String,
    branchName: String,
    path: String,
    startPoint: String
  ) throws {
    let trimmedBranchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedStartPoint = startPoint.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedBranchName.isEmpty else {
      throw GitError.commandFailed("Branch name is required.")
    }

    guard !trimmedPath.isEmpty else {
      throw GitError.commandFailed("Worktree path is required.")
    }

    let normalizedWorktreePath = normalizePath(trimmedPath)
    let parentDirectoryURL = URL(fileURLWithPath: normalizedWorktreePath)
      .deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: parentDirectoryURL,
        withIntermediateDirectories: true
      )
    } catch {
      throw GitError.commandFailed(
        "Could not create the worktree parent directory: \(error.localizedDescription)"
      )
    }

    _ = try requireGit([
      "-C", repoRoot,
      "worktree", "add",
      "-b", trimmedBranchName,
      normalizedWorktreePath,
      trimmedStartPoint.isEmpty ? "HEAD" : trimmedStartPoint,
    ])
  }

  static func hasUncommittedChanges(repoRoot: String) -> Bool {
    let output = runGit([
      "-C", repoRoot,
      "status", "--porcelain=1", "--untracked-files=all",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    return !output.isEmpty
  }

  static func removeWorktree(
    repoRoot: String,
    path: String,
    force: Bool = false
  ) throws {
    let normalizedWorktreePath = normalizePath(path)
    var arguments = [
      "-C", repoRoot,
      "worktree", "remove",
    ]
    if force {
      arguments.append("--force")
    }
    arguments.append(normalizedWorktreePath)
    _ = try requireGit(arguments)
  }

  static func branchHasUniqueCommits(
    repoRoot: String,
    branchName: String,
    baseRef: String?
  ) -> Bool {
    guard let baseRef, !baseRef.isEmpty else { return true }

    let output = runGit([
      "-C", repoRoot,
      "rev-list", "--count", "\(baseRef)..\(branchName)",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)

    guard let count = Int(output) else { return true }
    return count > 0
  }

  static func branchTopology(
    repoRoot: String,
    baseRef: String,
    headRef: String
  ) -> BranchTopology? {
    let output = runGit([
      "-C", repoRoot,
      "rev-list", "--left-right", "--count", "\(baseRef)...\(headRef)",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)

    let parts =
      output
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)

    guard parts.count == 2,
      let behindCount = Int(parts[0]),
      let aheadCount = Int(parts[1])
    else {
      return nil
    }

    return BranchTopology(aheadCount: aheadCount, behindCount: behindCount)
  }

  static func preferredBranchDeletionBaseRef(
    repoRoot: String,
    branchName: String?
  ) -> String? {
    let trimmedBranchName = branchName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let currentBranch = currentBranchName(repoRoot: repoRoot),
      !currentBranch.isEmpty,
      currentBranch != trimmedBranchName
    {
      return currentBranch
    }

    return inferBaseRef(repoRoot: repoRoot)
  }

  static func deleteBranch(
    repoRoot: String,
    branchName: String,
    force: Bool = false
  ) throws {
    let trimmedBranchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBranchName.isEmpty else {
      throw GitError.commandFailed("Branch name is required.")
    }

    _ = try requireGit([
      "-C", repoRoot,
      "branch", force ? "-D" : "-d",
      trimmedBranchName,
    ])
  }

  static func diffSummary(repoRoot: String) -> WorktreeDiffSummary {
    let files = diffFiles(repoRoot: repoRoot)
    guard !files.isEmpty else {
      return .empty
    }

    return WorktreeDiffSummary(
      fileCount: files.count,
      addedLineCount: files.reduce(0) { $0 + $1.addedCount },
      removedLineCount: files.reduce(0) { $0 + $1.removedCount }
    )
  }

  static func diffStat(repoRoot: String) -> String {
    formatDiffStat(files: diffFiles(repoRoot: repoRoot))
  }

  static func diffFiles(repoRoot: String) -> [FileDiff] {
    guard let target = autoDetectTarget(repoRoot: repoRoot) else {
      return []
    }

    let diffOutput = diff(
      repoRoot: repoRoot,
      mode: target.mode,
      baseRef: target.baseRef,
      headRef: target.headRef,
      mergeBaseSha: target.mergeBaseSha
    )
    return DiffParser.parse(diffOutput)
  }

  static func hasConflicts(repoRoot: String) -> Bool {
    let output = runGit([
      "-C", repoRoot, "diff", "--name-only", "--diff-filter=U",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    return !output.isEmpty
  }

  static func pullRequestCompareURL(
    repoRoot: String,
    mode: ReviewMode,
    baseRef: String,
    headRef: String
  ) -> String? {
    guard mode == .branch, let repositoryURL = githubRepositoryURL(repoRoot: repoRoot) else {
      return nil
    }

    let baseBranch = githubBranchName(baseRef)
    let headBranch = githubBranchName(headRef)
    guard !baseBranch.isEmpty, !headBranch.isEmpty, baseBranch != headBranch else { return nil }

    return "\(repositoryURL)/compare/\(baseBranch)...\(headBranch)?expand=1"
  }

  static func pullRequestURL(
    repoRoot: String,
    mode: ReviewMode,
    baseRef: String,
    headRef: String
  ) -> String? {
    guard mode == .branch else { return nil }
    return existingPullRequestURL(
      repoRoot: repoRoot,
      baseRef: baseRef,
      headRef: headRef
    )
      ?? pullRequestCompareURL(
        repoRoot: repoRoot,
        mode: mode,
        baseRef: baseRef,
        headRef: headRef
      )
  }

  static func formatDiffStat(files: [FileDiff]) -> String {
    guard !files.isEmpty else { return "" }

    let displayPaths = files.map(\.displayPath)
    let pathColumnWidth = min(
      max(displayPaths.map(\.count).max() ?? 0, 12),
      52
    )

    let lines = files.map { file -> String in
      let displayPath =
        if file.displayPath.count > pathColumnWidth {
          String(file.displayPath.suffix(pathColumnWidth))
        } else {
          file.displayPath
        }
      let padding = String(repeating: " ", count: max(pathColumnWidth - displayPath.count, 0))
      let lineDelta = file.addedCount + file.removedCount
      let graph = diffStatGraph(added: file.addedCount, removed: file.removedCount)
      return "\(displayPath)\(padding) | \(lineDelta) \(graph)"
    }

    let added = files.reduce(0) { $0 + $1.addedCount }
    let removed = files.reduce(0) { $0 + $1.removedCount }
    let summary = "\(files.count) files changed, \(added) insertions(+), \(removed) deletions(-)"

    return (lines + [summary]).joined(separator: "\n")
  }

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

  private static func diffStatGraph(added: Int, removed: Int) -> String {
    let total = max(added + removed, 1)
    let maxWidth = 16
    let addedUnits = min(
      maxWidth, max(1, Int(round(Double(added) / Double(total) * Double(maxWidth)))))
    let removedUnits =
      removed == 0
      ? 0
      : max(
        1,
        min(
          maxWidth - min(addedUnits, maxWidth),
          Int(round(Double(removed) / Double(total) * Double(maxWidth)))))

    return String(repeating: "+", count: added > 0 ? addedUnits : 0)
      + String(repeating: "-", count: removed > 0 ? removedUnits : 0)
  }

  private static func githubRepositoryURL(repoRoot: String) -> String? {
    let remoteURL = runGit([
      "-C", repoRoot, "remote", "get-url", "origin",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !remoteURL.isEmpty else { return nil }

    let path: String
    if remoteURL.hasPrefix("git@github.com:") {
      path = String(remoteURL.dropFirst("git@github.com:".count))
    } else if remoteURL.hasPrefix("ssh://git@github.com/") {
      path = String(remoteURL.dropFirst("ssh://git@github.com/".count))
    } else if remoteURL.hasPrefix("https://github.com/") {
      path = String(remoteURL.dropFirst("https://github.com/".count))
    } else if remoteURL.hasPrefix("http://github.com/") {
      path = String(remoteURL.dropFirst("http://github.com/".count))
    } else if remoteURL.hasPrefix("git://github.com/") {
      path = String(remoteURL.dropFirst("git://github.com/".count))
    } else {
      return nil
    }

    let trimmedPath =
      path.hasSuffix(".git")
      ? String(path.dropLast(4))
      : path
    let normalizedPath = trimmedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !normalizedPath.isEmpty else { return nil }
    return "https://github.com/\(normalizedPath)"
  }

  private static func githubBranchName(_ ref: String) -> String {
    ref
      .replacingOccurrences(of: "refs/heads/", with: "")
      .replacingOccurrences(of: "refs/remotes/", with: "")
      .replacingOccurrences(of: "origin/", with: "")
  }

  private static func existingPullRequestURL(
    repoRoot: String,
    baseRef: String,
    headRef: String
  ) -> String? {
    guard githubRepositoryURL(repoRoot: repoRoot) != nil else { return nil }

    let baseBranch = githubBranchName(baseRef)
    let headBranch = githubBranchName(headRef)
    guard !baseBranch.isEmpty, !headBranch.isEmpty, baseBranch != headBranch else { return nil }

    let result = runCommand(
      executable: "/usr/bin/env",
      arguments: [
        "gh", "pr", "view",
        "--json", "url",
        "--head", headBranch,
        "--base", baseBranch,
      ],
      currentDirectoryPath: repoRoot,
      environment: [
        "GH_PROMPT_DISABLED": "1",
        "NO_COLOR": "1",
      ]
    )

    guard result.terminationStatus == 0, !result.stdout.isEmpty else { return nil }
    guard
      let data = result.stdout.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let url = object["url"] as? String,
      !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    return url
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

  private static func parseWorktreeList(
    _ output: String,
    baseWorktreePath: String
  ) -> [DiscoveredWorktree] {
    let normalizedBasePath = normalizePath(baseWorktreePath)
    var worktrees: [DiscoveredWorktree] = []

    var currentPath: String?
    var currentBranch: String?
    var currentHeadSHA: String?
    var isDetached = false

    func flushCurrentWorktree() {
      guard let path = currentPath else { return }
      let normalizedPath = normalizePath(path)
      worktrees.append(
        DiscoveredWorktree(
          path: normalizedPath,
          branchName: currentBranch,
          headSHA: currentHeadSHA,
          isBaseWorktree: normalizedPath == normalizedBasePath,
          isDetached: isDetached
        ))
      currentPath = nil
      currentBranch = nil
      currentHeadSHA = nil
      isDetached = false
    }

    for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if line.isEmpty {
        flushCurrentWorktree()
        continue
      }

      if line.hasPrefix("worktree ") {
        flushCurrentWorktree()
        currentPath = String(line.dropFirst("worktree ".count))
        continue
      }

      if line.hasPrefix("branch ") {
        let branchRef = String(line.dropFirst("branch ".count))
        currentBranch = branchRef.replacingOccurrences(of: "refs/heads/", with: "")
        continue
      }

      if line.hasPrefix("HEAD ") {
        currentHeadSHA = String(line.dropFirst("HEAD ".count))
        continue
      }

      if line == "detached" {
        isDetached = true
      }
    }

    flushCurrentWorktree()

    return worktrees.sorted { lhs, rhs in
      if lhs.isBaseWorktree != rhs.isBaseWorktree {
        return lhs.isBaseWorktree && !rhs.isBaseWorktree
      }
      let lhsBranch = lhs.branchName ?? lhs.path
      let rhsBranch = rhs.branchName ?? rhs.path
      return lhsBranch.localizedStandardCompare(rhsBranch) == .orderedAscending
    }
  }

  private static func baseWorktreePath(repoCommonDir: String) -> String? {
    let commonDirURL = URL(fileURLWithPath: repoCommonDir).standardizedFileURL
    guard commonDirURL.lastPathComponent == ".git" else { return nil }
    return commonDirURL.deletingLastPathComponent().path
  }

  private static func normalizePath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private static func runCommand(
    executable: String,
    arguments: [String],
    currentDirectoryPath: String? = nil,
    environment: [String: String]? = nil
  ) -> CommandResult {
    if let commandRunner {
      return commandRunner(executable, arguments, currentDirectoryPath, environment)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let currentDirectoryPath {
      process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath)
    }
    if let environment {
      var merged = ProcessInfo.processInfo.environment
      for (key, value) in environment {
        merged[key] = value
      }
      process.environment = merged
    }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      return CommandResult(terminationStatus: -1, stdout: "", stderr: error.localizedDescription)
    }

    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(
      terminationStatus: process.terminationStatus,
      stdout: String(decoding: stdoutData, as: UTF8.self),
      stderr: String(decoding: stderrData, as: UTF8.self)
    )
  }

  static func requireGit(_ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      throw GitError.commandFailed(error.localizedDescription)
    }

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let message =
        String(data: errorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw GitError.commandFailed(
        message.map { $0.isEmpty ? "Git command failed." : $0 } ?? "Git command failed.")
    }

    return String(data: outputData, encoding: .utf8) ?? ""
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

struct CommandResult: Equatable, Sendable {
  let terminationStatus: Int32
  let stdout: String
  let stderr: String
}
