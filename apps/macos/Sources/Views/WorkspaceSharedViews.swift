import AppKit
import SwiftUI

struct WorkspaceSurface<Content: View>: View {
  let fillColor: Color
  @ViewBuilder let content: Content

  init(
    fillColor: Color = Color(nsColor: .controlBackgroundColor).opacity(0.88),
    @ViewBuilder content: () -> Content
  ) {
    self.fillColor = fillColor
    self.content = content()
  }

  var body: some View {
    content
      .padding(18)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(fillColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.primary.opacity(0.06), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.03), radius: 14, y: 4)
  }
}

struct WorkspaceBackground: View {
  var body: some View {
    LinearGradient(
      colors: [
        Color(nsColor: .windowBackgroundColor),
        Color(nsColor: .controlBackgroundColor).opacity(0.94),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .overlay(alignment: .topLeading) {
      Circle()
        .fill(Color.accentColor.opacity(0.14))
        .frame(width: 320, height: 320)
        .blur(radius: 100)
        .offset(x: -80, y: -140)
    }
    .overlay(alignment: .bottomTrailing) {
      Circle()
        .fill(Color.orange.opacity(0.07))
        .frame(width: 300, height: 300)
        .blur(radius: 100)
        .offset(x: 80, y: 120)
    }
    .overlay(alignment: .trailing) {
      Circle()
        .fill(Color.blue.opacity(0.05))
        .frame(width: 220, height: 220)
        .blur(radius: 90)
        .offset(x: 100, y: -30)
    }
  }
}

struct WorkspaceBanner: View {
  let message: String
  let symbolName: String
  let tint: Color
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
      Text(message)
        .lineLimit(2)
      Spacer()
      Button(action: onDismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .foregroundStyle(tint.opacity(0.85))
    }
    .font(.caption)
    .foregroundStyle(tint)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(tint.opacity(0.08))
  }
}

struct WorkspaceToast: View {
  let message: String
  let symbolName: String
  let tint: Color
  let accessibilityIdentifier: String?
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
      Text(message)
        .lineLimit(2)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .foregroundStyle(tint.opacity(0.85))
    }
    .font(.caption)
    .foregroundStyle(tint)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(message)
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.regularMaterial, in: Capsule())
    .overlay(
      Capsule()
        .stroke(tint.opacity(0.18), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    .padding(.horizontal, 16)
    .accessibilityIdentifier(accessibilityIdentifier ?? "workspace-toast")
  }
}

struct WorkspaceBadge: View {
  let label: String
  let tint: Color

  var body: some View {
    Text(label)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(tint.opacity(0.08), in: Capsule())
      .foregroundStyle(tint)
  }
}

struct WorkspaceDiffModePicker: View {
  @Environment(WorkspaceState.self) private var workspaceState

  var body: some View {
    Menu {
      Button {
        workspaceState.selectDiffMode(.allChanges)
      } label: {
        Label("All changes", systemImage: "arrow.triangle.branch")
      }
      .disabled(!workspaceState.selectedWorktreeSupportsAllChanges)

      Button {
        workspaceState.selectDiffMode(.uncommitted)
      } label: {
        Label("Uncommitted changes", systemImage: "pencil.and.outline")
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: activeModeIcon)
        Text(activeModeLabel)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .disabled(!workspaceState.selectedWorktreeSupportsAllChanges)
    .help(helpText)
  }

  private var activeModeLabel: String {
    switch workspaceState.selectedDiffMode {
    case .allChanges:
      "all changes"
    case .uncommitted:
      "uncommitted"
    }
  }

  private var activeModeIcon: String {
    switch workspaceState.selectedDiffMode {
    case .allChanges:
      "arrow.triangle.branch"
    case .uncommitted:
      "pencil.and.outline"
    }
  }

  private var helpText: String {
    workspaceState.selectedWorktreeSupportsAllChanges
      ? "Choose the worktree diff scope"
      : "The base worktree shows uncommitted changes"
  }
}

struct WorkspaceCompactDiffSummary: View {
  let summary: WorktreeDiffSummary
  var showsBar = true
  var usesCompactNumbers = false

  var body: some View {
    Group {
      if summary.hasChanges {
        HStack(spacing: 4) {
          Text(fileCountLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)

          Text("+\(formatted(summary.addedLineCount))")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(Color(nsColor: .systemGreen))

          Text("-\(formatted(summary.removedLineCount))")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(Color(nsColor: .systemRed))

          if showsBar {
            DiffStatBar(added: summary.addedLineCount, removed: summary.removedLineCount)
          }
        }
      } else {
        Text("no changes")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .fixedSize()
  }

  private var fileCountLabel: String {
    let count = summary.fileCount
    return count == 1 ? "1 file" : "\(formatted(count)) files"
  }

  private func formatted(_ value: Int) -> String {
    if usesCompactNumbers {
      return compactFormatted(value)
    }

    return WorkspaceCompactDiffSummary.numberFormatter.string(from: NSNumber(value: value))
      ?? "\(value)"
  }

  private func compactFormatted(_ value: Int) -> String {
    let absoluteValue = abs(value)

    if absoluteValue >= 1_000_000 {
      return "\(formattedCompactDecimal(Double(value) / 1_000_000))m"
    }

    if absoluteValue >= 10_000 {
      return "\(formattedCompactDecimal(Double(value) / 1_000))k"
    }

    return WorkspaceCompactDiffSummary.numberFormatter.string(from: NSNumber(value: value))
      ?? "\(value)"
  }

  private func formattedCompactDecimal(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded.rounded() == rounded {
      return "\(Int(rounded))"
    }

    return String(format: "%.1f", rounded)
  }

  private static let numberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter
  }()
}

struct WorkspaceEditorLauncher: View {
  @Environment(WorkspaceState.self) private var workspaceState
  let worktreePath: String
  @State private var editors: [DetectedEditorApp] = []
  @State private var preferredBundleIdentifier: String?
  @State private var openingBundleIdentifier: String?

  var body: some View {
    Group {
      if let preferredEditor {
        HStack(spacing: 0) {
          Button {
            openEditor(preferredEditor)
          } label: {
            HStack(spacing: 8) {
              Image(nsImage: EditorLocator.icon(for: preferredEditor, size: 16))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)

              if openingBundleIdentifier == preferredEditor.bundleIdentifier {
                ProgressView()
                  .controlSize(.small)
              } else {
                Text("Open in \(preferredEditor.displayName)")
                  .lineLimit(1)
              }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
          }
          .buttonStyle(.plain)
          .disabled(openingBundleIdentifier != nil)

          if !alternativeEditors.isEmpty {
            Rectangle()
              .fill(Color.primary.opacity(0.08))
              .frame(width: 1)
              .padding(.vertical, 6)

            Menu {
              ForEach(alternativeEditors) { editor in
                Button {
                  openEditor(editor)
                } label: {
                  HStack(spacing: 8) {
                    Image(nsImage: EditorLocator.icon(for: editor, size: 16))
                      .resizable()
                      .aspectRatio(contentMode: .fit)
                      .frame(width: 16, height: 16)
                    Text(editor.displayName)
                  }
                }
              }
            } label: {
              Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 30, height: 30)
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .disabled(openingBundleIdentifier != nil)
            .help("Choose another editor")
          }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 32, maxHeight: 32)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
      } else {
        Button {
          loadEditors()
        } label: {
          Label("No Editor Found", systemImage: "questionmark.app.dashed")
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.bordered)
      }
    }
    .task(id: worktreePath) {
      loadEditors()
    }
  }

  private var preferredEditor: DetectedEditorApp? {
    if let preferredBundleIdentifier,
      let preferredEditor = editors.first(where: {
        $0.bundleIdentifier == preferredBundleIdentifier
      })
    {
      return preferredEditor
    }

    return EditorPreferenceStore.preferredEditor(for: worktreePath, among: editors)
  }

  private var alternativeEditors: [DetectedEditorApp] {
    EditorPreferenceStore.alternativeEditors(for: worktreePath, among: editors)
  }

  private func loadEditors() {
    editors = EditorLocator.discoverInstalledEditors()
    preferredBundleIdentifier = EditorPreferenceStore.preferredBundleIdentifier(for: worktreePath)
  }

  private func chooseEditor(_ editor: DetectedEditorApp) {
    preferredBundleIdentifier = editor.bundleIdentifier
    EditorPreferenceStore.setPreferredBundleIdentifier(
      editor.bundleIdentifier,
      for: worktreePath
    )
  }

  private func openEditor(_ editor: DetectedEditorApp) {
    chooseEditor(editor)
    openingBundleIdentifier = editor.bundleIdentifier

    Task {
      do {
        try await EditorLocator.open(editor, worktreePath: worktreePath)
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
      openingBundleIdentifier = nil
    }
  }
}

struct WorkspaceSidebarHoverActions: View {
  let worktree: DiscoveredWorktree
  let isVisible: Bool

  var body: some View {
    HStack(spacing: 2) {
      WorkspaceRevealInFinderButton(
        worktreePath: worktree.path,
        isVisible: isVisible
      )

      if !worktree.isBaseWorktree {
        WorkspaceRemoveWorktreeButton(
          worktree: worktree,
          isVisible: isVisible
        )
      }
    }
    .padding(3)
    .background(
      Capsule()
        .fill(Color(nsColor: .controlBackgroundColor).opacity(isVisible ? 0.9 : 0))
    )
    .overlay {
      Capsule()
        .stroke(Color.primary.opacity(isVisible ? 0.08 : 0), lineWidth: 1)
    }
  }
}

struct WorkspaceRevealInFinderButton: View {
  let worktreePath: String
  let isVisible: Bool

  var body: some View {
    Button {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktreePath)])
    } label: {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .padding(3)
        .background(
          Circle()
            .fill(Color.primary.opacity(showButton ? 0.06 : 0))
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .opacity(showButton ? 1 : 0)
    .allowsHitTesting(showButton)
    .help("Reveal worktree in Finder")
    .accessibilityLabel("Reveal in Finder")
  }

  private var showButton: Bool {
    isVisible
  }
}

struct WorkspaceRemoveWorktreeButton: View {
  @Environment(WorkspaceState.self) private var workspaceState
  let worktree: DiscoveredWorktree
  let isVisible: Bool
  @State private var pendingRemoval: WorktreeRemovalRequest?
  @State private var deleteBranchOnConfirm = false
  @State private var isPreparingRemoval = false
  @State private var isRemoving = false

  var body: some View {
    Button(role: .destructive) {
      prepareRemoval()
    } label: {
      ZStack {
        Image(systemName: "trash")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.red)
          .opacity(isShowingProgress ? 0 : 1)

        if isShowingProgress {
          ProgressView()
            .controlSize(.small)
        }
      }
      .frame(width: 18, height: 18)
      .padding(3)
      .background(
        Circle()
          .fill(Color.red.opacity(showButton ? 0.09 : 0))
      )
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(isShowingProgress)
    .opacity(showButton ? 1 : 0)
    .allowsHitTesting(showButton)
    .help("Delete worktree")
    .accessibilityLabel("Delete worktree")
    .sheet(isPresented: isPresentingRemovalSheet) {
      if let pendingRemoval {
        WorkspaceRemoveWorktreeConfirmationSheet(
          request: pendingRemoval,
          deleteBranch: $deleteBranchOnConfirm,
          onCancel: { self.pendingRemoval = nil },
          onConfirm: { confirmRemoval() }
        )
      }
    }
  }

  private var isShowingProgress: Bool {
    isPreparingRemoval || isRemoving
  }

  private var showButton: Bool {
    isVisible || isShowingProgress
  }

  private var isPresentingRemovalSheet: Binding<Bool> {
    Binding(
      get: { pendingRemoval != nil },
      set: { isPresented in
        if !isPresented {
          pendingRemoval = nil
        }
      }
    )
  }

  private func prepareRemoval() {
    guard !isShowingProgress else { return }
    isPreparingRemoval = true

    Task {
      defer { isPreparingRemoval = false }
      do {
        let removalRequest = try await workspaceState.prepareWorktreeRemoval(for: worktree)
        if removalRequest.shouldSkipConfirmation {
          executeRemoval(removalRequest, deleteBranch: removalRequest.defaultDeletesBranch)
        } else {
          deleteBranchOnConfirm = removalRequest.defaultDeletesBranch
          pendingRemoval = removalRequest
        }
      } catch {
        workspaceState.presentWorktreeRemovalError(error, worktreeName: worktreeDisplayName)
      }
    }
  }

  private func confirmRemoval() {
    guard let pendingRemoval else { return }
    self.pendingRemoval = nil
    executeRemoval(pendingRemoval, deleteBranch: deleteBranchOnConfirm)
  }

  private func executeRemoval(_ pendingRemoval: WorktreeRemovalRequest, deleteBranch: Bool) {
    isRemoving = true

    Task {
      defer { isRemoving = false }
      do {
        try await workspaceState.removeWorktree(pendingRemoval, deleteBranch: deleteBranch)
      } catch {
        workspaceState.presentWorktreeRemovalError(error, worktreeName: pendingRemoval.displayName)
      }
    }
  }

  private var worktreeDisplayName: String {
    worktree.branchName ?? URL(fileURLWithPath: worktree.path).lastPathComponent
  }
}

struct WorkspaceRemoveWorktreeConfirmationSheet: View {
  let request: WorktreeRemovalRequest
  @Binding var deleteBranch: Bool
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Delete \(request.displayName)?")
        .font(.title3.weight(.semibold))

      Text(removalMessage)
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if !submoduleRiskMessages.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(submoduleRiskMessages, id: \.self) { message in
            Text(message)
              .font(.caption)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      }

      if request.canDeleteBranch, let branchName = request.branchName {
        Toggle(isOn: $deleteBranch) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Delete branch \(branchName)")
              .font(.body.weight(.medium))
            Text(branchSubtitle)
              .font(.caption)
              .foregroundStyle(branchSubtitleColor)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .toggleStyle(.checkbox)
      }

      HStack(spacing: 10) {
        Spacer()

        Button("Cancel", role: .cancel) {
          onCancel()
        }

        Button(deleteButtonTitle, role: .destructive) {
          onConfirm()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 430)
  }

  private var removalMessage: String {
    let removedContent =
      request.hasInitializedSubmodules
      ? "the worktree directory and initialized submodule checkouts"
      : "the worktree directory"

    if request.hasUncommittedChanges {
      return
        "This worktree has uncommitted changes. Deleting it will remove \(removedContent) and discard those changes."
    }

    return "This will remove \(removedContent) from disk."
  }

  private var deleteButtonTitle: String {
    if request.canDeleteBranch && deleteBranch {
      return "Delete Worktree and Branch"
    }

    return "Delete Worktree"
  }

  private var branchSubtitle: String {
    if request.branchHasUniqueCommits && request.branchHasUnpushedCommits {
      if let baseRef = request.branchComparisonBaseRef {
        return "Contains commits not merged into \(baseRef) and not pushed to a remote."
      }
      return "Contains commits that are not confirmed as merged or pushed."
    }

    if request.branchHasUniqueCommits {
      if let baseRef = request.branchComparisonBaseRef {
        return "Contains commits not merged into \(baseRef)."
      }
      return "Contains commits that are not confirmed as merged."
    }

    if request.branchHasUnpushedCommits {
      return "Contains commits not pushed to a remote."
    }

    if let baseRef = request.branchComparisonBaseRef {
      return "Already merged into \(baseRef)."
    }
    return "No unmerged commits detected."
  }

  private var branchSubtitleColor: Color {
    if (request.branchHasUniqueCommits || request.branchHasUnpushedCommits) && deleteBranch {
      return .red
    }
    return .secondary
  }

  private var submoduleRiskMessages: [String] {
    request.submodulesWithUnpushedCommits.map { submodule in
      if let commitCount = submodule.commitCount {
        return
          "\(submodule.path) contains \(commitCount) \(commitNoun(for: commitCount)) not pushed to a remote."
      }
      return "Argon could not confirm that \(submodule.path)'s commits are pushed to a remote."
    }
  }

  private func commitNoun(for count: Int) -> String {
    count == 1 ? "commit" : "commits"
  }
}
