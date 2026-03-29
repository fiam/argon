import SwiftUI

@MainActor
@Observable
final class AppState {
    var session: ReviewSession?
    var files: [FileDiff] = []
    var selectedFile: FileDiff?
    var errorMessage: String?
    var isLoading = false
    var isPolling = false
    var pendingDrafts: [DraftComment] = []

    // Active review target (may differ from the session's original target)
    var activeMode: ReviewMode = .uncommitted
    var activeBaseRef: String = "HEAD"
    var activeHeadRef: String = "WORKTREE"
    var activeMergeBaseSha: String = ""

    // Available branch info for the mode picker
    var detectedBaseRef: String?
    var detectedHeadRef: String?

    var sessionId: String?
    var repoRoot: String?

    private var pollTask: Task<Void, Never>?

    init() {
        parseArguments()
    }

    private func parseArguments() {
        let args = ProcessInfo.processInfo.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--session-id" where i + 1 < args.count:
                sessionId = args[i + 1]
                i += 2
            case "--repo-root" where i + 1 < args.count:
                repoRoot = args[i + 1]
                i += 2
            default:
                i += 1
            }
        }
    }

    func loadSession() {
        guard let sessionId, let repoRoot else {
            errorMessage = "No session. Run: argon . from a git repo"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let newSession = try SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
            session = newSession

            // Initialize active target from session
            activeMode = newSession.mode
            activeBaseRef = newSession.baseRef
            activeHeadRef = newSession.headRef
            activeMergeBaseSha = newSession.mergeBaseSha

            // Detect branch info for mode picker
            detectedBaseRef = GitService.inferBaseRef(repoRoot: repoRoot)
            detectedHeadRef = GitService.currentBranchName(repoRoot: repoRoot)

            refreshDiff()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchMode(_ mode: ReviewMode) {
        guard let repoRoot else { return }

        let target: ResolvedTarget?
        switch mode {
        case .branch:
            let base = detectedBaseRef ?? "main"
            let head = detectedHeadRef ?? "HEAD"
            target = GitService.resolveBranchTarget(repoRoot: repoRoot, baseRef: base, headRef: head)
        case .commit:
            target = GitService.resolveCommitTarget(repoRoot: repoRoot)
        case .uncommitted:
            target = GitService.resolveUncommittedTarget(repoRoot: repoRoot)
        }

        guard let target else {
            errorMessage = "Could not resolve \(mode.rawValue) target"
            return
        }

        activeMode = target.mode
        activeBaseRef = target.baseRef
        activeHeadRef = target.headRef
        activeMergeBaseSha = target.mergeBaseSha

        // Update the session on disk so the CLI sees the new target
        if let sid = sessionId {
            do {
                try ArgonCLI.updateSessionTarget(
                    sessionId: sid, repoRoot: repoRoot,
                    mode: target.mode.rawValue, baseRef: target.baseRef,
                    headRef: target.headRef, mergeBaseSha: target.mergeBaseSha
                )
                refreshSession()
            } catch {
                // Non-fatal — the diff still works locally
            }
        }

        refreshDiff()
    }

    private func refreshDiff() {
        guard let repoRoot else { return }
        let rawDiff = GitService.diff(
            repoRoot: repoRoot, mode: activeMode,
            baseRef: activeBaseRef, headRef: activeHeadRef,
            mergeBaseSha: activeMergeBaseSha
        )
        files = DiffParser.parse(rawDiff)
        if selectedFile == nil || !files.contains(where: { $0.id == selectedFile?.id }) {
            selectedFile = files.first
        }
    }

    func reload() {
        errorMessage = nil
        loadSession()
    }

    func refreshSession() {
        guard let sessionId, let repoRoot else { return }
        do {
            session = try SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
        } catch {
            // Ignore transient read errors during polling
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { break }
                self?.refreshSession()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    func closeSession() {
        guard let sessionId, let repoRoot else { return }
        do {
            try ArgonCLI.closeSession(sessionId: sessionId, repoRoot: repoRoot)
            refreshSession()
        } catch {}
        stopPolling()
    }

    // MARK: - Draft Review

    func addDraft(message: String, filePath: String? = nil, lineNew: UInt32? = nil, lineOld: UInt32? = nil, threadId: String? = nil) {
        guard let sessionId, let repoRoot else { return }
        do {
            try ArgonCLI.addDraftComment(
                sessionId: sessionId, repoRoot: repoRoot,
                message: message, filePath: filePath,
                lineNew: lineNew, lineOld: lineOld, threadId: threadId
            )
            reloadDrafts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteDraft(_ draftId: String) {
        guard let sessionId, let repoRoot else { return }
        do {
            try ArgonCLI.deleteDraftComment(sessionId: sessionId, repoRoot: repoRoot, draftId: draftId)
            reloadDrafts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitReview(outcome: String?, summary: String? = nil) {
        guard let sessionId, let repoRoot else { return }
        do {
            try ArgonCLI.submitReview(
                sessionId: sessionId, repoRoot: repoRoot,
                outcome: outcome, summary: summary
            )
            pendingDrafts = []
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadDrafts() {
        guard let sessionId, let repoRoot else { return }
        do {
            pendingDrafts = try SessionLoader.loadDraftReview(sessionId: sessionId, repoRoot: repoRoot)
        } catch {
            pendingDrafts = []
        }
    }

    var handoffCommand: String {
        guard let sessionId, let repoRoot else { return "" }
        let cli = ProcessInfo.processInfo.environment["ARGON_CLI_CMD"] ?? "argon"
        return "\(cli) --repo \(repoRoot) agent prompt --session \(sessionId)"
    }
}
