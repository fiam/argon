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

    var activeMode: ReviewMode = .uncommitted
    var activeBaseRef: String = "HEAD"
    var activeHeadRef: String = "WORKTREE"
    var activeMergeBaseSha: String = ""

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

    // MARK: - Load

    func loadSession() {
        guard let sessionId, let repoRoot else {
            errorMessage = "No session. Run: argon . from a git repo"
            return
        }

        isLoading = true
        let sid = sessionId
        let root = repoRoot

        Task {
            let result = await Task.detached {
                Self.doLoadSession(sessionId: sid, repoRoot: root)
            }.value

            isLoading = false
            switch result {
            case .success(let data):
                session = data.session
                activeMode = data.session.mode
                activeBaseRef = data.session.baseRef
                activeHeadRef = data.session.headRef
                activeMergeBaseSha = data.session.mergeBaseSha
                detectedBaseRef = data.detectedBase
                detectedHeadRef = data.detectedHead
                files = data.files
                if selectedFile == nil || !data.files.contains(where: { $0.id == selectedFile?.id }) {
                    selectedFile = data.files.first
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Switch Mode

    func switchMode(_ mode: ReviewMode) {
        guard let repoRoot else { return }
        isLoading = true

        let sid = sessionId
        let root = repoRoot
        let dBase = detectedBaseRef
        let dHead = detectedHeadRef

        Task {
            let result = await Task.detached {
                Self.doSwitchMode(
                    mode: mode, repoRoot: root, sessionId: sid,
                    detectedBase: dBase, detectedHead: dHead
                )
            }.value

            isLoading = false
            switch result {
            case .success(let data):
                activeMode = data.target.mode
                activeBaseRef = data.target.baseRef
                activeHeadRef = data.target.headRef
                activeMergeBaseSha = data.target.mergeBaseSha
                files = data.files
                if selectedFile == nil || !data.files.contains(where: { $0.id == selectedFile?.id }) {
                    selectedFile = data.files.first
                }
                if let s = data.updatedSession {
                    session = s
                }
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
    }

    // MARK: - Background helpers

    private enum SwitchError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let msg): msg }
        }
    }

    private struct LoadData: Sendable {
        let session: ReviewSession
        let files: [FileDiff]
        let detectedBase: String?
        let detectedHead: String?
    }

    private struct SwitchData: Sendable {
        let target: ResolvedTarget
        let files: [FileDiff]
        let updatedSession: ReviewSession?
    }

    nonisolated private static func doLoadSession(sessionId: String, repoRoot: String) -> Result<LoadData, Error> {
        do {
            let session = try SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
            let rawDiff = GitService.diff(session: session)
            let files = DiffParser.parse(rawDiff)
            let detectedBase = GitService.inferBaseRef(repoRoot: repoRoot)
            let detectedHead = GitService.currentBranchName(repoRoot: repoRoot)
            return .success(LoadData(session: session, files: files, detectedBase: detectedBase, detectedHead: detectedHead))
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func doSwitchMode(
        mode: ReviewMode, repoRoot: String, sessionId: String?,
        detectedBase: String?, detectedHead: String?
    ) -> Result<SwitchData, SwitchError> {

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
            return .failure(.failed("Could not resolve \(mode.rawValue) target"))
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

        return .success(SwitchData(target: target, files: files, updatedSession: updatedSession))
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
