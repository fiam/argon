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

  var displayLabel: String? {
    switch (aheadCount, behindCount) {
    case (0, 0):
      nil
    case (let ahead, 0):
      "\(ahead) \(Self.commitNoun(for: ahead)) ahead"
    case (0, let behind):
      "\(behind) \(Self.commitNoun(for: behind)) behind"
    case (let ahead, let behind):
      "\(ahead) \(Self.commitNoun(for: ahead)) ahead, \(behind) \(Self.commitNoun(for: behind)) behind"
    }
  }

  private static func commitNoun(for count: Int) -> String {
    count == 1 ? "commit" : "commits"
  }
}

struct FastForwardMergeBackRequest: Hashable, Sendable {
  let repoRoot: String
  let worktreePath: String
  let branchName: String
  let baseRef: String
  let headRef: String
}

struct FastForwardMergeBackResult: Hashable, Sendable {
  let baseBranchName: String
  let headBranchName: String
  let branchHead: String
  let landedCommitCount: Int

  var message: String {
    let commitLabel = landedCommitCount == 1 ? "commit" : "commits"
    return
      "Fast-forwarded \(baseBranchName) to \(headBranchName) (\(landedCommitCount) \(commitLabel))."
  }
}

struct DiscoveredWorktree: Identifiable, Hashable, Sendable {
  var id: String { path }

  let path: String
  let branchName: String?
  let headSHA: String?
  let isBaseWorktree: Bool
  let isDetached: Bool
  let createdAt: Date?

  init(
    path: String,
    branchName: String?,
    headSHA: String?,
    isBaseWorktree: Bool,
    isDetached: Bool,
    createdAt: Date? = nil
  ) {
    self.path = path
    self.branchName = branchName
    self.headSHA = headSHA
    self.isBaseWorktree = isBaseWorktree
    self.isDetached = isDetached
    self.createdAt = createdAt
  }
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

struct SubmoduleUnpushedCommits: Identifiable, Hashable, Sendable {
  var id: String { path }

  let path: String
  let commitCount: Int?
}

enum WorkspaceDiffMode: String, CaseIterable, Hashable, Sendable {
  case allChanges
  case uncommitted
}

enum GitService {
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
      baseWorktreePath: baseWorktreePath(repoCommonDir: repoCommonDir) ?? repoRoot,
      createdAtProvider: worktreeCreatedAt
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

    if let upstream = branchNameForStartPoint(
      repoRoot: repoRoot,
      startPoint: trimmedStartPoint.isEmpty ? "HEAD" : trimmedStartPoint
    ),
      upstream != trimmedBranchName
    {
      _ = runGit([
        "-C", repoRoot,
        "branch", "--set-upstream-to", upstream, trimmedBranchName,
      ])
    }
  }

  static func hasUncommittedChanges(repoRoot: String) -> Bool {
    let output = runGit([
      "-C", repoRoot,
      "status", "--porcelain=1", "--untracked-files=all",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    return !output.isEmpty
  }

  static func hasInitializedSubmodules(repoRoot: String) -> Bool {
    !initializedSubmodulePaths(repoRoot: repoRoot).isEmpty
  }

  static func submodulesWithUnpushedCommits(repoRoot: String) -> [SubmoduleUnpushedCommits] {
    initializedSubmodulePaths(repoRoot: repoRoot).compactMap { path in
      let submoduleRoot = normalizePath(
        URL(fileURLWithPath: repoRoot).appendingPathComponent(path).path
      )
      guard resolveRef(repoRoot: submoduleRoot, ref: "HEAD") != nil else {
        return SubmoduleUnpushedCommits(path: path, commitCount: nil)
      }

      let count = commitCountNotReachable(
        repoRoot: submoduleRoot,
        ref: "HEAD",
        protectedRefs: remoteRefs(repoRoot: submoduleRoot)
      )
      guard let count else {
        return SubmoduleUnpushedCommits(path: path, commitCount: nil)
      }
      return count > 0 ? SubmoduleUnpushedCommits(path: path, commitCount: count) : nil
    }
  }

  static func removeWorktree(
    repoRoot: String,
    path: String,
    force: Bool = false
  ) throws {
    let normalizedWorktreePath = normalizePath(path)
    let containsInitializedSubmodules = hasInitializedSubmodules(repoRoot: normalizedWorktreePath)
    if containsInitializedSubmodules && !force
      && hasUncommittedChanges(repoRoot: normalizedWorktreePath)
    {
      throw GitError.commandFailed(
        "The worktree has uncommitted changes. Confirm removal before deleting it."
      )
    }

    var arguments = [
      "-C", repoRoot,
      "worktree", "remove",
    ]
    if force || containsInitializedSubmodules {
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

    return refHasCommitsNotProtectedByPatchID(
      repoRoot: repoRoot,
      ref: branchName,
      protectedRefs: [baseRef]
    )
  }

  static func branchHasUnpushedCommits(
    repoRoot: String,
    branchName: String,
    baseRef: String?
  ) -> Bool {
    let trimmedBranchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBranchName.isEmpty else { return false }

    let protectedRefs =
      ([baseRef?.trimmingCharacters(in: .whitespacesAndNewlines)].compactMap { ref in
        guard let ref, !ref.isEmpty else { return nil }
        return ref
      } + remoteRefs(repoRoot: repoRoot))

    return refHasCommitsNotProtectedByPatchID(
      repoRoot: repoRoot,
      ref: trimmedBranchName,
      protectedRefs: protectedRefs
    )
  }

  static func branchRequiresForceDelete(
    repoRoot: String,
    branchName: String,
    baseRef: String?
  ) -> Bool {
    guard let baseRef, !baseRef.isEmpty else { return true }

    guard
      let count = commitCountNotReachable(
        repoRoot: repoRoot,
        ref: branchName,
        protectedRefs: [baseRef]
      )
    else {
      return true
    }
    return count > 0
  }

  static func branchTopology(
    repoRoot: String,
    baseRef: String,
    headRef: String
  ) -> BranchTopology? {
    guard let mergeBase = mergeBase(repoRoot: repoRoot, a: baseRef, b: headRef),
      let behindCount = commitCount(repoRoot: repoRoot, range: "\(mergeBase)..\(baseRef)"),
      let aheadCount = commitCount(repoRoot: repoRoot, range: "\(mergeBase)..\(headRef)")
    else { return nil }

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

  static func fastForwardMergeBack(
    _ request: FastForwardMergeBackRequest
  ) throws -> FastForwardMergeBackResult {
    let repoRoot = normalizePath(request.repoRoot)
    let worktreePath = normalizePath(request.worktreePath)
    let branchName = request.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseRef = request.baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
    let headRef = request.headRef.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !branchName.isEmpty else {
      throw GitError.commandFailed("Branch name is required.")
    }
    guard !baseRef.isEmpty else {
      throw GitError.commandFailed("Base branch is required.")
    }

    guard let baseBranchName = currentBranchName(repoRoot: repoRoot) else {
      throw GitError.commandFailed("The base worktree must be on a branch.")
    }
    let expectedBaseBranchName = githubBranchName(baseRef)
    guard baseBranchName == baseRef || baseBranchName == expectedBaseBranchName else {
      throw GitError.commandFailed(
        "The base worktree is on \(baseBranchName), not \(expectedBaseBranchName)."
      )
    }

    guard !hasUncommittedChanges(repoRoot: repoRoot) else {
      throw GitError.commandFailed("The base worktree has uncommitted changes.")
    }
    guard !hasUncommittedChanges(repoRoot: worktreePath) else {
      throw GitError.commandFailed("The linked worktree has uncommitted changes.")
    }

    guard let baseHead = resolveRef(repoRoot: repoRoot, ref: "HEAD"),
      let expectedBaseHead = resolveRef(repoRoot: repoRoot, ref: baseRef)
    else {
      throw GitError.commandFailed("Could not resolve the base branch.")
    }
    guard baseHead == expectedBaseHead else {
      throw GitError.commandFailed("The base worktree is not up to date with \(baseRef).")
    }

    let mergeHeadRef = headRef.isEmpty ? branchName : headRef
    guard let branchHead = resolveRef(repoRoot: repoRoot, ref: mergeHeadRef) else {
      throw GitError.commandFailed("Could not resolve \(branchName).")
    }
    guard isAncestor(repoRoot: repoRoot, ancestor: "HEAD", descendant: branchHead) else {
      throw GitError.commandFailed("\(baseBranchName) cannot be fast-forwarded to \(branchName).")
    }

    let landedCommitCount = commitCount(repoRoot: repoRoot, range: "HEAD..\(branchHead)") ?? 0
    guard landedCommitCount > 0 else {
      throw GitError.commandFailed("\(branchName) has no commits to land.")
    }

    _ = try requireGit([
      "-C", repoRoot,
      "merge", "--ff-only",
      branchHead,
    ])

    guard resolveRef(repoRoot: repoRoot, ref: "HEAD") == branchHead else {
      throw GitError.commandFailed(
        "Fast-forward did not update \(baseBranchName) to \(branchName).")
    }

    return FastForwardMergeBackResult(
      baseBranchName: baseBranchName,
      headBranchName: branchName,
      branchHead: branchHead,
      landedCommitCount: landedCommitCount
    )
  }

  static func diffSummary(
    repoRoot: String,
    diffMode: WorkspaceDiffMode = .allChanges
  ) -> WorktreeDiffSummary {
    let files = diffFiles(repoRoot: repoRoot, diffMode: diffMode)
    guard !files.isEmpty else {
      return .empty
    }

    return WorktreeDiffSummary(
      fileCount: files.count,
      addedLineCount: files.reduce(0) { $0 + $1.addedCount },
      removedLineCount: files.reduce(0) { $0 + $1.removedCount }
    )
  }

  static func diffStat(
    repoRoot: String,
    diffMode: WorkspaceDiffMode = .allChanges
  ) -> String {
    formatDiffStat(files: diffFiles(repoRoot: repoRoot, diffMode: diffMode))
  }

  static func diffFiles(
    repoRoot: String,
    diffMode: WorkspaceDiffMode = .allChanges
  ) -> [FileDiff] {
    guard let target = resolveWorkspaceTarget(repoRoot: repoRoot, diffMode: diffMode) else {
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
    if let mergeability = try? ArgonCLI.workspaceMergeability(repoRoot: repoRoot) {
      return mergeability.status == .conflicted
    }

    // Fallback for development/test environments where the bundled CLI is not
    // available yet. Production conflict prediction comes from argon-core.
    return hasUnmergedFiles(repoRoot: repoRoot)
  }

  private static func hasUnmergedFiles(repoRoot: String) -> Bool {
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
    var includeUntracked = true
    switch mode {
    case .branch:
      args.append(mergeBaseSha)
      if let currentHead = resolveRef(repoRoot: repoRoot, ref: "HEAD"),
        let targetHead = resolveRef(repoRoot: repoRoot, ref: headRef),
        currentHead != targetHead
      {
        args.append(headRef)
        includeUntracked = false
      }
    case .uncommitted:
      args.append("HEAD")
    }
    var result = runGit(args)

    // Untracked files with sizes (so content changes are detected)
    let untrackedList = includeUntracked ? untrackedFiles(repoRoot: repoRoot) : []
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
    var includeUntracked = true

    switch mode {
    case .branch:
      args.append(mergeBaseSha)
      if let currentHead = resolveRef(repoRoot: repoRoot, ref: "HEAD"),
        let targetHead = resolveRef(repoRoot: repoRoot, ref: headRef),
        currentHead != targetHead
      {
        args.append(headRef)
        includeUntracked = false
      }
    case .uncommitted:
      args.append("HEAD")
    }

    var result = runGit(args)

    // Append untracked (non-ignored) files as diffs against /dev/null
    let untrackedFiles = includeUntracked ? untrackedFiles(repoRoot: repoRoot) : []
    for file in untrackedFiles {
      let fileDiff = runGit([
        "-C", repoRoot, "diff", "--no-color", "--unified=3", "--no-ext-diff",
        "--no-index", "/dev/null", file,
      ])
      if !fileDiff.isEmpty {
        if !result.isEmpty && !result.hasSuffix("\n") {
          result += "\n"
        }
        result += fileDiff
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
    resolveWorkspaceTarget(repoRoot: repoRoot, diffMode: .allChanges)
  }

  static func resolveWorkspaceTarget(
    repoRoot: String,
    diffMode: WorkspaceDiffMode
  ) -> ResolvedTarget? {
    if diffMode == .uncommitted || isHeadDetached(repoRoot: repoRoot) {
      return resolveUncommittedTarget(repoRoot: repoRoot)
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

  private static func branchNameForStartPoint(repoRoot: String, startPoint: String) -> String? {
    if startPoint == "HEAD" {
      return currentBranchName(repoRoot: repoRoot)
    }

    let output = runGit([
      "-C", repoRoot, "rev-parse", "--abbrev-ref", "--symbolic-full-name", startPoint,
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty, output != "HEAD", resolveRef(repoRoot: repoRoot, ref: output) != nil
    else {
      return nil
    }
    return output
  }

  static func inferBaseRef(repoRoot: String) -> String? {
    if let currentBranch = currentBranchName(repoRoot: repoRoot) {
      if let upstream = upstreamRef(repoRoot: repoRoot), githubBranchName(upstream) != currentBranch
      {
        return upstream
      }

      if let baseRef = nearestWorktreeBranchBase(repoRoot: repoRoot, currentBranch: currentBranch) {
        return baseRef
      }
    }

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

  static func defaultWorktreeStartPoint(repoRoot: String, baseRef: String?) -> String {
    let trimmedBaseRef = baseRef?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedBaseRef =
      if let trimmedBaseRef, !trimmedBaseRef.isEmpty {
        trimmedBaseRef
      } else {
        inferBaseRef(repoRoot: repoRoot)
      }

    guard let resolvedBaseRef, !resolvedBaseRef.isEmpty else { return "HEAD" }

    return localBranchStartPoint(repoRoot: repoRoot, remoteRef: resolvedBaseRef)
      ?? resolvedBaseRef
  }

  private static func nearestWorktreeBranchBase(
    repoRoot: String,
    currentBranch: String
  ) -> String? {
    let output = runGit(["-C", repoRoot, "worktree", "list", "--porcelain"])
    let candidates = Set(
      output
        .split(separator: "\n")
        .compactMap { line -> String? in
          let prefix = "branch refs/heads/"
          guard line.hasPrefix(prefix) else { return nil }
          let branch = String(line.dropFirst(prefix.count))
          return branch == currentBranch ? nil : branch
        }
    ).sorted()

    var best: (tier: Int, distance: Int, ref: String)?
    for candidate in candidates {
      if isAncestor(repoRoot: repoRoot, ancestor: currentBranch, descendant: candidate) {
        continue
      }

      let mergeBase = runGit(["-C", repoRoot, "merge-base", currentBranch, candidate])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !mergeBase.isEmpty else { continue }

      let distanceOutput = runGit([
        "-C", repoRoot, "rev-list", "--count", "\(mergeBase)..\(currentBranch)",
      ])
      guard let distance = Int(distanceOutput.trimmingCharacters(in: .whitespacesAndNewlines))
      else {
        continue
      }
      let tier =
        isAncestor(repoRoot: repoRoot, ancestor: candidate, descendant: currentBranch) ? 0 : 1

      if let currentBest = best {
        let candidateIsBetter =
          tier < currentBest.tier
          || (tier == currentBest.tier && distance < currentBest.distance)
          || (tier == currentBest.tier && distance == currentBest.distance
            && candidate < currentBest.ref)
        if !candidateIsBetter {
          continue
        }
      }
      best = (tier, distance, candidate)
    }

    return best?.ref
  }

  private static func upstreamRef(repoRoot: String) -> String? {
    let output = runGit([
      "-C", repoRoot, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
  }

  private static func isAncestor(
    repoRoot: String,
    ancestor: String,
    descendant: String
  ) -> Bool {
    runCommand(
      executable: "/usr/bin/git",
      arguments: ["-C", repoRoot, "merge-base", "--is-ancestor", ancestor, descendant]
    ).terminationStatus == 0
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

  private static func commitCount(repoRoot: String, range: String) -> Int? {
    let output = runGit(["-C", repoRoot, "rev-list", "--count", range])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Int(output)
  }

  private static func commitCountNotReachable(
    repoRoot: String,
    ref: String,
    protectedRefs: [String]
  ) -> Int? {
    var arguments = [
      "-C", repoRoot,
      "rev-list", "--count",
      ref,
    ]

    let trimmedProtectedRefs = protectedRefs.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    if !trimmedProtectedRefs.isEmpty {
      arguments.append("--not")
      arguments.append(contentsOf: trimmedProtectedRefs)
    }

    let output = runGit(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    return Int(output)
  }

  private static func commitsNotReachable(
    repoRoot: String,
    ref: String,
    protectedRefs: [String]
  ) -> [String]? {
    var arguments = [
      "-C", repoRoot,
      "rev-list",
      ref,
    ]

    let trimmedProtectedRefs = existingRefs(repoRoot: repoRoot, refs: protectedRefs)
    if !trimmedProtectedRefs.isEmpty {
      arguments.append("--not")
      arguments.append(contentsOf: trimmedProtectedRefs)
    }

    let output = runGit(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    if output.isEmpty { return [] }

    let commits =
      output
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return commits.isEmpty ? nil : commits
  }

  private static func refHasCommitsNotProtectedByPatchID(
    repoRoot: String,
    ref: String,
    protectedRefs: [String]
  ) -> Bool {
    let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRef.isEmpty else { return false }
    guard resolveRef(repoRoot: repoRoot, ref: trimmedRef) != nil else { return true }

    let existingProtectedRefs = existingRefs(repoRoot: repoRoot, refs: protectedRefs)
    guard !existingProtectedRefs.isEmpty else { return true }

    guard
      let commits = commitsNotReachable(
        repoRoot: repoRoot,
        ref: trimmedRef,
        protectedRefs: existingProtectedRefs
      )
    else {
      return true
    }

    return commits.contains { commit in
      !commitPatchExists(repoRoot: repoRoot, commit: commit, protectedRefs: existingProtectedRefs)
    }
  }

  private static func commitPatchExists(
    repoRoot: String,
    commit: String,
    protectedRefs: [String]
  ) -> Bool {
    protectedRefs.contains { protectedRef in
      var arguments = [
        "-C", repoRoot,
        "cherry",
        protectedRef,
        commit,
      ]
      if let parent = firstParent(repoRoot: repoRoot, commit: commit) {
        arguments.append(parent)
      }

      return runGit(arguments)
        .split(whereSeparator: \.isNewline)
        .contains { line in
          line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("- ")
        }
    }
  }

  private static func firstParent(repoRoot: String, commit: String) -> String? {
    let output = runGit([
      "-C", repoRoot,
      "rev-list", "--parents", "-n", "1",
      commit,
    ])
    .trimmingCharacters(in: .whitespacesAndNewlines)

    return
      output
      .split(separator: " ")
      .dropFirst()
      .first
      .map(String.init)
  }

  private static func existingRefs(repoRoot: String, refs: [String]) -> [String] {
    refs.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    .filter { !$0.isEmpty }
    .filter { resolveRef(repoRoot: repoRoot, ref: $0) != nil }
  }

  private static func remoteRefs(repoRoot: String) -> [String] {
    runGit([
      "-C", repoRoot,
      "for-each-ref", "--format=%(refname)", "refs/remotes",
    ])
    .split(whereSeparator: \.isNewline)
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
  }

  private static func initializedSubmodulePaths(repoRoot: String) -> [String] {
    runGit([
      "-C", repoRoot,
      "submodule", "foreach", "--recursive", "--quiet",
      #"printf '%s\n' "$sm_path""#,
    ])
    .split(whereSeparator: \.isNewline)
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
  }

  private static func localBranchStartPoint(repoRoot: String, remoteRef: String) -> String? {
    let unqualifiedRemoteRef =
      if remoteRef.hasPrefix("refs/remotes/") {
        String(remoteRef.dropFirst("refs/remotes/".count))
      } else {
        remoteRef
      }

    for remoteName in remoteNames(repoRoot: repoRoot) {
      let prefix = "\(remoteName)/"
      guard unqualifiedRemoteRef.hasPrefix(prefix) else { continue }

      let localRef = String(unqualifiedRemoteRef.dropFirst(prefix.count))
      guard !localRef.isEmpty,
        resolveRef(repoRoot: repoRoot, ref: localRef) != nil
      else {
        return nil
      }
      return localRef
    }

    return nil
  }

  private static func remoteNames(repoRoot: String) -> [String] {
    runGit(["-C", repoRoot, "remote"])
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
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
    }
  }

  private static func oldSideContextLines(
    repoRoot: String,
    filePath: String,
    mode: ReviewMode,
    mergeBaseSha: String
  ) -> [String]? {
    let ref: String =
      switch mode {
      case .branch:
        mergeBaseSha
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

  static func parseWorktreeList(
    _ output: String,
    baseWorktreePath: String,
    createdAtProvider: (String) -> Date?
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
          isDetached: isDetached,
          createdAt: createdAtProvider(normalizedPath)
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

      switch (lhs.createdAt, rhs.createdAt) {
      case (.some(let lhsCreatedAt), .some(let rhsCreatedAt))
      where lhsCreatedAt != rhsCreatedAt:
        return lhsCreatedAt < rhsCreatedAt
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      default:
        return compareWorktreeNames(lhs, rhs)
      }
    }
  }

  private static func compareWorktreeNames(
    _ lhs: DiscoveredWorktree,
    _ rhs: DiscoveredWorktree
  ) -> Bool {
    let lhsName = lhs.branchName ?? lhs.path
    let rhsName = rhs.branchName ?? rhs.path
    let nameComparison = lhsName.localizedStandardCompare(rhsName)
    if nameComparison != .orderedSame {
      return nameComparison == .orderedAscending
    }

    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
  }

  private static func worktreeCreatedAt(path: String) -> Date? {
    let worktreeURL = URL(fileURLWithPath: path, isDirectory: true)
    let gitMetadataURL = worktreeURL.appendingPathComponent(".git")

    return fileCreatedAt(gitMetadataURL) ?? fileCreatedAt(worktreeURL)
  }

  private static func fileCreatedAt(_ url: URL) -> Date? {
    guard
      let values = try? url.resourceValues(forKeys: [.creationDateKey])
    else {
      return nil
    }

    return values.creationDate
  }

  private static func baseWorktreePath(repoCommonDir: String) -> String? {
    let commonDirURL = URL(fileURLWithPath: repoCommonDir).standardizedFileURL
    guard commonDirURL.lastPathComponent == ".git" else { return nil }
    return commonDirURL.deletingLastPathComponent().path
  }

  private static func normalizePath(_ path: String) -> String {
    let normalized = URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    return normalizedDarwinPrivatePath(normalized)
  }

  private static func normalizedDarwinPrivatePath(_ path: String) -> String {
    for (privatePrefix, publicPrefix) in [
      ("/private/tmp", "/tmp"),
      ("/private/var", "/var"),
      ("/private/etc", "/etc"),
    ] {
      if path == privatePrefix {
        return publicPrefix
      }
      if path.hasPrefix("\(privatePrefix)/") {
        return publicPrefix + path.dropFirst(privatePrefix.count)
      }
    }

    return path
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
