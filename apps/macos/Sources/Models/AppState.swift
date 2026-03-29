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
    var scrollToFile: UUID?

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

        Task.detached { [sessionId, repoRoot] in
            let result = Self.loadSessionInBackground(sessionId: sessionId, repoRoot: repoRoot)
            await MainActor.run { [self] in
                self.isLoading = false
                switch result {
                case .success(let data):
                    self.session = data.session
                    self.activeMode = data.session.mode
                    self.activeBaseRef = data.session.baseRef
                    self.activeHeadRef = data.session.headRef
                    self.activeMergeBaseSha = data.session.mergeBaseSha
                    self.detectedBaseRef = data.detectedBase
                    self.detectedHeadRef = data.detectedHead
                    self.files = data.files
                    if self.selectedFile == nil || !data.files.contains(where: { $0.id == self.selectedFile?.id }) {
                        self.selectedFile = data.files.first
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func switchMode(_ mode: ReviewMode) {
        guard let repoRoot else { return }
        isLoading = true

        let sessionId = self.sessionId
        let detectedBase = self.detectedBaseRef
        let detectedHead = self.detectedHeadRef

        Task.detached { [repoRoot] in
            let result = Self.switchModeInBackground(
                mode: mode, repoRoot: repoRoot, sessionId: sessionId,
                detectedBase: detectedBase, detectedHead: detectedHead
            )
            await MainActor.run { [self] in
                self.isLoading = false
                switch result {
                case .success(let data):
                    self.activeMode = data.target.mode
                    self.activeBaseRef = data.target.baseRef
                    self.activeHeadRef = data.target.headRef
                    self.activeMergeBaseSha = data.target.mergeBaseSha
                    self.files = data.files
                    if self.selectedFile == nil || !data.files.contains(where: { $0.id == self.selectedFile?.id }) {
                        self.selectedFile = data.files.first
                    }
                    if let session = data.updatedSession {
                        self.session = session
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Background Work

    private struct LoadResult {
        let session: ReviewSession
        let files: [FileDiff]
        let detectedBase: String?
        let detectedHead: String?
    }

    private struct SwitchResult {
        let target: ResolvedTarget
        let files: [FileDiff]
        let updatedSession: ReviewSession?
    }

    nonisolated private static func loadSessionInBackground(sessionId: String, repoRoot: String) -> Result<LoadResult, Error> {
        do {
            let session = try SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
            let rawDiff = GitService.diff(session: session)
            let files = DiffParser.parse(rawDiff)
            let detectedBase = GitService.inferBaseRef(repoRoot: repoRoot)
            let detectedHead = GitService.currentBranchName(repoRoot: repoRoot)
            return .success(LoadResult(session: session, files: files, detectedBase: detectedBase, detectedHead: detectedHead))
        } catch {
            return .failure(error)
        }
    }

    private enum SwitchError: LocalizedError {
        case resolveFailed(String)
        var errorDescription: String? {
            switch self { case .resolveFailed(let msg): msg }
        }
    }

    nonisolated private static func switchModeInBackground(
        mode: ReviewMode, repoRoot: String, sessionId: String?,
        detectedBase: String?, detectedHead: String?
    ) -> Result<SwitchResult, SwitchError> {
        let target: ResolvedTarget?
        switch mode {
        case .branch:
            let base = detectedBase ?? "main"
            let head = detectedHead ?? "HEAD"
            target = GitService.resolveBranchTarget(repoRoot: repoRoot, baseRef: base, headRef: head)
        case .commit:
            target = GitService.resolveCommitTarget(repoRoot: repoRoot)
        case .uncommitted:
            target = GitService.resolveUncommittedTarget(repoRoot: repoRoot)
        }

        guard let target else {
            return .failure(.resolveFailed("Could not resolve \(mode.rawValue) target"))
        }

        let rawDiff = GitService.diff(
            repoRoot: repoRoot, mode: target.mode,
            baseRef: target.baseRef, headRef: target.headRef,
            mergeBaseSha: target.mergeBaseSha
        )
        let files = DiffParser.parse(rawDiff)

        var updatedSession: ReviewSession?
        if let sessionId {
            try? ArgonCLI.updateSessionTarget(
                sessionId: sessionId, repoRoot: repoRoot,
                mode: target.mode.rawValue, baseRef: target.baseRef,
                headRef: target.headRef, mergeBaseSha: target.mergeBaseSha
            )
            updatedSession = try? SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
        }

        return .success(SwitchResult(target: target, files: files, updatedSession: updatedSession))
    }

    // MARK: - Polling

    func refreshSession() {
        guard let sessionId, let repoRoot else { return }
        do {
            session = try SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
        } catch {}
    }

    func reload() {
        errorMessage = nil
        loadSession()
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
