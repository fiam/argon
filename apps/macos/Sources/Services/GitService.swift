import Foundation

struct ResolvedTarget {
    let mode: ReviewMode
    let baseRef: String
    let headRef: String
    let mergeBaseSha: String
}

enum GitService {

    // MARK: - Diff Fingerprint (lightweight check for changes)

    /// Returns a short stat string that changes when the diff content changes.
    static func diffFingerprint(repoRoot: String, mode: ReviewMode, baseRef: String, headRef: String, mergeBaseSha: String) -> String {
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
        case .uncommitted:
            args.append("HEAD")
        }

        return runGit(args)
    }

    // MARK: - Diff

    static func diff(repoRoot: String, mode: ReviewMode, baseRef: String, headRef: String, mergeBaseSha: String) -> String {
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
        case .uncommitted:
            args.append("HEAD")
        }

        return runGit(args)
    }

    static func diff(session: ReviewSession) -> String {
        diff(repoRoot: session.repoRoot, mode: session.mode,
             baseRef: session.baseRef, headRef: session.headRef,
             mergeBaseSha: session.mergeBaseSha)
    }

    // MARK: - Target Detection

    /// Auto-detect the best review mode for the repo.
    static func autoDetectTarget(repoRoot: String) -> ResolvedTarget? {
        if isHeadDetached(repoRoot: repoRoot) {
            return resolveCommitTarget(repoRoot: repoRoot)
        }

        guard let currentBranch = currentBranchName(repoRoot: repoRoot),
              let baseRef = inferBaseRef(repoRoot: repoRoot) else {
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

    static func resolveBranchTarget(repoRoot: String, baseRef: String, headRef: String) -> ResolvedTarget? {
        guard let mergeBase = mergeBase(repoRoot: repoRoot, a: baseRef, b: headRef) else { return nil }
        return ResolvedTarget(mode: .branch, baseRef: baseRef, headRef: headRef, mergeBaseSha: mergeBase)
    }

    static func resolveCommitTarget(repoRoot: String, commitRef: String = "HEAD") -> ResolvedTarget? {
        guard let sha = resolveRef(repoRoot: repoRoot, ref: commitRef) else { return nil }
        let base = commitRef == "HEAD" ? "HEAD" : sha
        return ResolvedTarget(mode: .commit, baseRef: base, headRef: "WORKTREE", mergeBaseSha: sha)
    }

    static func resolveUncommittedTarget(repoRoot: String) -> ResolvedTarget? {
        guard let sha = resolveRef(repoRoot: repoRoot, ref: "HEAD") else { return nil }
        return ResolvedTarget(mode: .uncommitted, baseRef: "HEAD", headRef: "WORKTREE", mergeBaseSha: sha)
    }

    // MARK: - Git Helpers

    static func currentBranchName(repoRoot: String) -> String? {
        let output = runGit(["-C", repoRoot, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty || output == "HEAD" { return nil }
        return output
    }

    static func inferBaseRef(repoRoot: String) -> String? {
        // Try origin/HEAD
        let originHead = runGit(["-C", repoRoot, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let output = runGit(["-C", repoRoot, "merge-base", a, b]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    static func resolveRef(repoRoot: String, ref: String) -> String? {
        let output = runGit(["-C", repoRoot, "rev-parse", "--verify", "\(ref)^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
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
