import AppKit
import SwiftUI

struct WorkspaceCenterPane: View {
  @Environment(WorkspaceState.self) private var workspaceState

  var body: some View {
    GeometryReader { proxy in
      Group {
        if workspaceState.selectedWorktree != nil {
          WorkspaceTerminalDeck()
            .padding(.bottom, 20)
        } else if workspaceState.isLoading {
          ProgressView("Loading workspace...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView(
            "Select a Worktree",
            systemImage: "square.stack.3d.up",
            description: Text("Choose a worktree from the sidebar to inspect it.")
          )
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
  }
}

struct WorkspaceToolbarItems: ToolbarContent {
  let showsFinalizeControls: Bool
  let showsReviewProgress: Bool
  let showsRebaseProgress: Bool
  let showsMergeBackProgress: Bool
  let isReviewDisabled: Bool
  let canRebase: Bool
  let canMergeBack: Bool
  let canOpenPR: Bool
  let branchTopologyLabel: String?
  let onPresentTabCreator: () -> Void
  let onReview: () -> Void
  let onRebase: () -> Void
  let onMergeBack: () -> Void
  let onOpenPR: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button(action: onPresentTabCreator) {
        Image(systemName: "plus")
      }
      .help("New tab")
      .accessibilityLabel("New Tab")
    }

    if #available(macOS 26.0, *) {
      ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    ToolbarItem(placement: .primaryAction) {
      Button(action: onReview) {
        Image(systemName: showsReviewProgress ? "ellipsis" : "text.magnifyingglass")
      }
      .help(
        isReviewDisabled
          ? "Close the review window to enable review for this worktree again."
          : "Start review"
      )
      .accessibilityLabel("Start Review")
      .accessibilityIdentifier("workspace-review-button")
      .disabled(isReviewDisabled)
    }

    ToolbarItem(placement: .primaryAction) {
      if showsRebaseProgress {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
          .frame(width: 24, height: 24)
          .help(rebaseHelpText)
          .accessibilityLabel("Rebase Running")
          .accessibilityIdentifier("workspace-rebase-running-indicator")
      } else {
        Button(action: onRebase) {
          Image(systemName: "arrow.clockwise")
        }
        .help(rebaseHelpText)
        .accessibilityLabel("Rebase onto Base")
        .accessibilityIdentifier("workspace-rebase-button")
        .disabled(!showsFinalizeControls || !canRebase)
      }
    }

    ToolbarItem(placement: .primaryAction) {
      if showsMergeBackProgress {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
          .frame(width: 24, height: 24)
          .help(mergeBackHelpText)
          .accessibilityLabel("Merge Back Running")
          .accessibilityIdentifier("workspace-merge-back-running-indicator")
      } else {
        Button(action: onMergeBack) {
          Image(systemName: "arrow.triangle.branch")
        }
        .help(mergeBackHelpText)
        .accessibilityLabel("Merge Back")
        .accessibilityIdentifier("workspace-merge-back-button")
        .disabled(!showsFinalizeControls || !canMergeBack)
      }
    }

    ToolbarItem(placement: .primaryAction) {
      Button(action: onOpenPR) {
        Image(systemName: "arrow.up.forward.app")
      }
      .help(openPRHelpText)
      .accessibilityLabel("Open Pull Request")
      .accessibilityIdentifier("workspace-open-pr-button")
      .disabled(!showsFinalizeControls || !canOpenPR)
    }
  }

  private var rebaseHelpText: String {
    if !showsFinalizeControls {
      return "The base worktree cannot be rebased onto itself."
    }
    if showsRebaseProgress {
      return "Rebase is running."
    }
    if !canRebase {
      return "Rebase is only available when this worktree is behind the base branch."
    }
    return "Rebase onto base branch"
  }

  private var mergeBackHelpText: String {
    if !showsFinalizeControls {
      return "The base worktree is already the landing branch."
    }
    if showsMergeBackProgress {
      return "Merge back is running."
    }
    if !canMergeBack {
      return "Merge Back requires a branch-backed worktree."
    }
    return finalizeHelpText("Merge back to base branch")
  }

  private var openPRHelpText: String {
    if !showsFinalizeControls {
      return "The base worktree does not open pull requests against itself."
    }
    if !canOpenPR {
      return "Open Pull Request is only available when this worktree has commits to propose."
    }
    return finalizeHelpText("Open pull request")
  }

  private func finalizeHelpText(_ text: String) -> String {
    guard let branchTopologyLabel else { return text }
    return "\(text). \(branchTopologyLabel)"
  }
}

struct WorkspaceChangedFilesPane: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @State private var selectedFileID: String?

  var body: some View {
    WorkspaceSurface(fillColor: Color(nsColor: .textBackgroundColor).opacity(0.98)) {
      if workspaceState.isLoadingSelectionDetails {
        VStack {
          ProgressView()
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        FileTreePanel(
          files: workspaceState.selectedFiles,
          emptyTitle: "No Changed Files",
          emptySystemImage: "checkmark.circle",
          emptyDescription: "This worktree is clean.",
          selectedFileID: selectedFileID,
          focusFilterRequest: false,
          onConsumeFocusFilterRequest: nil,
          onSelectFile: { file in
            selectedFileID = file.id
          },
          onOpenFile: { file in
            openFileInPreferredEditor(file)
          }
        )
        .id(workspaceState.normalizedSelectedWorktreePath ?? "workspace-file-tree")
      }
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .onChange(of: workspaceState.selectedWorktreePath) { _, _ in
      selectedFileID = nil
    }
  }

  private func openFileInPreferredEditor(_ file: FileDiff) {
    guard let worktree = workspaceState.selectedWorktree else { return }

    let editors = EditorLocator.discoverInstalledEditors()
    guard let editor = EditorPreferenceStore.preferredEditor(for: worktree.path, among: editors)
    else {
      workspaceState.errorMessage = "No supported editor found for this worktree."
      return
    }

    guard let relativePath = file.preferredOpenPath else {
      workspaceState.errorMessage = "This file cannot be opened from the current diff."
      return
    }

    let fileURL = URL(fileURLWithPath: worktree.path).appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      workspaceState.errorMessage = "Cannot open \(relativePath) because it no longer exists."
      return
    }

    Task {
      do {
        try await EditorLocator.open(editor, urls: [fileURL])
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }
}
