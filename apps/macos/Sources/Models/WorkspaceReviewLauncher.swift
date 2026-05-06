import AppKit
import Foundation

@MainActor
enum WorkspaceReviewLauncher {
  static func startReview(
    workspaceState: WorkspaceState,
    reviewWindowRegistry: ReviewWindowRegistry,
    openWindow: @escaping (ReviewTarget) -> Void
  ) {
    guard let worktreePath = workspaceState.selectedWorktree?.path else { return }

    if reviewWindowRegistry.bringToFront(repoRoot: worktreePath) {
      return
    }

    guard reviewWindowRegistry.state(for: worktreePath) != .opening else { return }

    guard let decision = workspaceState.beginReviewLaunchFlow() else { return }

    switch decision {
    case .useExistingAgent(let agentTabID, let preparation):
      let committedPreparation =
        workspaceState.commitPendingReviewPreparation()
        ?? preparation.normalized()
      launchReview(
        workspaceState: workspaceState,
        reviewWindowRegistry: reviewWindowRegistry,
        openWindow: openWindow,
        agentTabID: agentTabID,
        changeSummary: committedPreparation.draft.renderedSummary
      )
    case .chooseExistingAgent:
      break
    case .launchAgent:
      workspaceState.launchAgentForPendingReviewPreparation()
    }
  }

  static func launchReview(
    workspaceState: WorkspaceState,
    reviewWindowRegistry: ReviewWindowRegistry,
    openWindow: @escaping (ReviewTarget) -> Void,
    agentTabID: UUID,
    changeSummary: String? = nil
  ) {
    Task { @MainActor in
      do {
        let target: ReviewTarget
        if let preparedTarget = workspaceState.consumePreparedReviewTarget(for: agentTabID) {
          target = preparedTarget
        } else {
          target = try await workspaceState.createReviewTarget(
            launchContext: .coderHandoff,
            changeSummary: changeSummary
          )
          do {
            let prompt = try await Task.detached {
              try ArgonCLI.agentPrompt(sessionId: target.sessionId, repoRoot: target.repoRoot)
            }.value
            let injected = await GhosttyTerminalView.injectPrompt(prompt, into: agentTabID)
            if !injected {
              workspaceState.errorMessage =
                "Opened the review, but Argon could not hand off the session prompt to the selected agent tab."
            }
          } catch {
            workspaceState.errorMessage =
              "Opened the review, but Argon could not build the agent handoff prompt: \(error.localizedDescription)"
          }
        }
        reviewWindowRegistry.open(target: target) { target in
          openWindow(target)
        }
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  static func launchExternalReview(
    workspaceState: WorkspaceState,
    reviewWindowRegistry: ReviewWindowRegistry,
    openWindow: @escaping (ReviewTarget) -> Void,
    changeSummary: String? = nil
  ) {
    Task { @MainActor in
      do {
        let target = try await workspaceState.createReviewTarget(
          launchContext: .externalHandoff,
          changeSummary: changeSummary
        )
        do {
          let prompt = try await Task.detached {
            try ArgonCLI.agentPrompt(sessionId: target.sessionId, repoRoot: target.repoRoot)
          }.value
          copyToPasteboard(prompt)
          reviewWindowRegistry.open(target: target) { target in
            openWindow(target)
          }
        } catch {
          try? await Task.detached {
            try ArgonCLI.closeSession(sessionId: target.sessionId, repoRoot: target.repoRoot)
          }.value
          workspaceState.refreshReviewSnapshot(for: target.repoRoot)
          workspaceState.errorMessage =
            "Argon could not build the external agent handoff prompt: \(error.localizedDescription)"
        }
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  private static func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
