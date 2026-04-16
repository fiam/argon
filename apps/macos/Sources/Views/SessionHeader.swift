import SwiftUI

struct SessionHeader: View {
  @Environment(AppState.self) private var appState
  let session: ReviewSession
  let fileCount: Int
  @State private var showSubmitSheet = false
  @State private var submitSummary = ""
  @State private var submitOutcome: String = "commented"
  @State private var showPromptToast = false
  @State private var toastDismissWorkItem: DispatchWorkItem?

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) {
        StatusBadge(status: session.status)

        ModePicker()

        DiffStatView(files: appState.files)
      }

      if let summary = session.changeSummary {
        Divider().frame(height: 16)
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      // Reviewer agent decision banner
      if let decision = session.decision {
        Divider().frame(height: 16)
        DecisionBanner(decision: decision)
      }

      Spacer()

      DiffModeToggle()

      if session.status != .approved && session.status != .closed {
        AgentLaunchButton()
        if appState.showsCoderSetupActions {
          HandoffButton {
            showAgentPromptToast()
          }
        }
        CoderConnectionBadge()
        Divider().frame(height: 16)
        reviewActions
      } else if session.status == .approved {
        Label("Approved", systemImage: "checkmark.circle.fill")
          .font(.callout)
          .fontWeight(.medium)
          .foregroundStyle(.green)
      } else {
        Label("Closed", systemImage: "xmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(alignment: .bottomTrailing) {
      if showPromptToast {
        AgentPromptToast()
          .offset(x: -8, y: 40)
          .transition(.move(edge: .top).combined(with: .opacity))
          .allowsHitTesting(false)
          .zIndex(1)
      }
    }
    .zIndex(showPromptToast ? 2 : 0)
    .sheet(isPresented: $showSubmitSheet) {
      SubmitReviewSheet(
        draftCount: appState.pendingDrafts.count,
        outcome: $submitOutcome,
        summary: $submitSummary,
        onSubmit: {
          appState.submitReview(
            outcome: submitOutcome,
            summary: submitSummary.isEmpty ? nil : submitSummary
          )
          showSubmitSheet = false
          submitSummary = ""
          submitOutcome = "commented"
        },
        onCancel: {
          showSubmitSheet = false
          submitSummary = ""
        }
      )
    }
    .onAppear {
      appState.reloadDrafts()
    }
    .onDisappear {
      toastDismissWorkItem?.cancel()
      toastDismissWorkItem = nil
    }
  }

  @ViewBuilder
  private var reviewActions: some View {
    HStack(spacing: 8) {
      // Pending drafts badge
      if !appState.pendingDrafts.isEmpty {
        Text("\(appState.pendingDrafts.count) pending")
          .font(.caption)
          .fontWeight(.medium)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.purple.opacity(0.15))
          .foregroundStyle(.purple)
          .clipShape(Capsule())
      }

      Button {
        submitOutcome = "approved"
        showSubmitSheet = true
      } label: {
        Label("Submit Review", systemImage: "paperplane")
      }
      .controlSize(.small)
    }
  }

  private func showAgentPromptToast() {
    toastDismissWorkItem?.cancel()
    withAnimation(.easeInOut(duration: 0.2)) {
      showPromptToast = true
    }
    let workItem = DispatchWorkItem {
      withAnimation(.easeInOut(duration: 0.2)) {
        showPromptToast = false
      }
    }
    toastDismissWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
  }
}

// MARK: - Diff Mode Toggle

struct DiffModeToggle: View {
  @Environment(AppState.self) private var appState

  private var hasContent: Bool {
    !appState.files.isEmpty
  }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(DiffViewMode.allCases, id: \.self) { mode in
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            appState.diffMode = mode
          }
        } label: {
          Image(systemName: mode.icon)
            .font(.system(size: 12))
            .frame(width: 28, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.diffMode == mode ? .primary : .tertiary)
        .background(
          appState.diffMode == mode
            ? Color(nsColor: .controlAccentColor).opacity(0.12)
            : .clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help(mode.label)
      }
    }
    .padding(2)
    .background(Color(nsColor: .separatorColor).opacity(0.15))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .disabled(!hasContent)
    .opacity(hasContent ? 1 : 0.4)
  }
}

// MARK: - Mode Picker

struct ModePicker: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    Menu {
      Button {
        appState.requestModeSwitch(.branch)
      } label: {
        Label(branchLabel, systemImage: "arrow.triangle.branch")
      }
      .disabled(appState.detectedBaseRef == nil)

      Button {
        appState.requestModeSwitch(.commit)
      } label: {
        Label("Latest commit", systemImage: "clock.arrow.circlepath")
      }

      Button {
        appState.requestModeSwitch(.uncommitted)
      } label: {
        Label("Uncommitted changes", systemImage: "pencil.and.outline")
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: activeModeIcon)
        Text(activeModeLabel)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(!appState.canSwitchReviewMode)
    .help(appState.modeSwitchDisabledReason ?? "Switch review target")
    .alert(
      "Switch review target?",
      isPresented: Binding(
        get: { appState.showModeSwitchAlert },
        set: { presented in
          if presented {
            appState.showModeSwitchAlert = true
          } else {
            appState.cancelModeSwitch()
          }
        }
      )
    ) {
      Button("Switch", role: .destructive) {
        appState.confirmModeSwitch()
      }
      Button("Cancel", role: .cancel) {
        appState.cancelModeSwitch()
      }
    } message: {
      Text(
        "Switching the review target clears current review threads, pending drafts, the current decision, and any unsaved inline comment."
      )
    }
  }

  private var activeModeLabel: String {
    switch appState.activeMode {
    case .branch:
      "\(shorten(appState.activeBaseRef))...\(shorten(appState.activeHeadRef))"
    case .commit:
      "commit \(shorten(appState.activeHeadRef))"
    case .uncommitted:
      "uncommitted changes"
    }
  }

  private var activeModeIcon: String {
    switch appState.activeMode {
    case .branch: "arrow.triangle.branch"
    case .commit: "clock.arrow.circlepath"
    case .uncommitted: "pencil.and.outline"
    }
  }

  private var branchLabel: String {
    if let base = appState.detectedBaseRef, let head = appState.detectedHeadRef {
      return "\(shorten(base))...\(shorten(head))"
    }
    return "Branch (not available)"
  }

  private func shorten(_ ref: String) -> String {
    if ref.count > 25 { return String(ref.prefix(22)) + "..." }
    return ref
  }
}

struct SubmitReviewSheet: View {
  let draftCount: Int
  @Binding var outcome: String
  @Binding var summary: String
  let onSubmit: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      // Header
      HStack(spacing: 10) {
        Image(systemName: "paperplane.circle.fill")
          .font(.title)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("Submit Review")
            .font(.title2)
            .fontWeight(.semibold)
          if draftCount > 0 {
            Text("\(draftCount) pending comment\(draftCount == 1 ? "" : "s") will be submitted.")
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            Text("Submit a decision without comments.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }

      // Decision buttons
      VStack(alignment: .leading, spacing: 8) {
        Text("Decision")
          .font(.callout)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          DecisionOption(
            icon: "checkmark.circle.fill",
            label: "Approve",
            color: .green,
            tag: "approved",
            selected: $outcome
          )
          DecisionOption(
            icon: "arrow.uturn.backward.circle.fill",
            label: "Request Changes",
            color: .orange,
            tag: "changes-requested",
            selected: $outcome
          )
          DecisionOption(
            icon: "text.bubble.fill",
            label: "Comment",
            color: .blue,
            tag: "commented",
            selected: $outcome
          )
        }
      }

      // Summary
      VStack(alignment: .leading, spacing: 6) {
        Text("Summary (optional)")
          .font(.callout)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)

        TextEditor(text: $summary)
          .font(.system(.body, design: .monospaced))
          .frame(width: 460, height: 70)
          .scrollContentBackground(.hidden)
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
          )
      }

      // Actions
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button {
          onSubmit()
        } label: {
          Label(submitLabel, systemImage: submitIcon)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .tint(submitColor)
      }
    }
    .padding(24)
    .frame(width: 520)
  }

  private var submitLabel: String {
    switch outcome {
    case "approved": "Approve"
    case "changes-requested": "Request Changes"
    default: "Submit"
    }
  }

  private var submitIcon: String {
    switch outcome {
    case "approved": "checkmark.circle"
    case "changes-requested": "arrow.uturn.backward"
    default: "paperplane"
    }
  }

  private var submitColor: Color {
    switch outcome {
    case "approved": .green
    case "changes-requested": .orange
    default: .blue
    }
  }
}

struct DecisionOption: View {
  let icon: String
  let label: String
  let color: Color
  let tag: String
  @Binding var selected: String

  private var isSelected: Bool { selected == tag }

  var body: some View {
    Button {
      selected = tag
    } label: {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .foregroundStyle(isSelected ? color : .secondary)
        Text(label)
          .fontWeight(isSelected ? .medium : .regular)
      }
      .font(.callout)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(isSelected ? color.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
      .foregroundStyle(isSelected ? color : .primary)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(isSelected ? color.opacity(0.4) : Color(nsColor: .separatorColor), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}

struct DecisionBanner: View {
  let decision: ReviewDecision

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.caption)
      Text(label)
        .font(.caption)
        .fontWeight(.medium)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      if let summary = decision.summary, !summary.isEmpty {
        Text("— \(summary)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(color.opacity(0.12))
    .foregroundStyle(color)
    .clipShape(Capsule())
  }

  private var label: String {
    switch decision.outcome {
    case .approved: "Approved"
    case .changesRequested: "Changes Requested"
    case .commented: "Commented"
    }
  }

  private var icon: String {
    switch decision.outcome {
    case .approved: "checkmark.circle.fill"
    case .changesRequested: "arrow.uturn.backward.circle.fill"
    case .commented: "text.bubble.fill"
    }
  }

  private var color: Color {
    switch decision.outcome {
    case .approved: .green
    case .changesRequested: .orange
    case .commented: .blue
    }
  }
}

struct HandoffButton: View {
  @Environment(AppState.self) private var appState
  let onCopy: () -> Void

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(appState.handoffPrompt, forType: .string)
      onCopy()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: icon)
        Text("Copy Agent Prompt")
          .lineLimit(1)
      }
    }
    .controlSize(.small)
    .fixedSize()
    .background(attentionBackground)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(attentionBorder)
    .help(helpText)
    .accessibilityIdentifier("CoderHandoffButton")
  }

  private var icon: String {
    appState.coderNeedsPromptHandoff ? "bolt.badge.clock" : "doc.on.doc"
  }

  @ViewBuilder
  private var attentionBackground: some View {
    if appState.coderNeedsPromptHandoff {
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.orange.opacity(0.1))
    }
  }

  @ViewBuilder
  private var attentionBorder: some View {
    if appState.coderNeedsPromptHandoff {
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
    }
  }

  private var helpText: String {
    if appState.coderNeedsPromptHandoff {
      return
        "No coder agent heartbeat yet. Copy the full agent prompt, then paste it into your coder agent or start an agent with that prompt."
    }
    return
      "Copy the full agent prompt again. Paste it into your coder agent or start an agent with that prompt."
  }
}

private struct CoderConnectionBadge: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(appState.coderConnectionLabel)
        .lineLimit(1)
    }
    .font(.caption2)
    .fontWeight(.medium)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(color.opacity(0.14))
    .foregroundStyle(color)
    .clipShape(Capsule())
    .fixedSize()
    .help(appState.coderConnectionHelpText)
    .accessibilityIdentifier("CoderConnectionBadge")
  }

  private var color: Color {
    switch appState.coderConnectionState {
    case .awaitingConnection:
      appState.coderHandoffPendingFromWorkspace ? .blue : .orange
    case .connected:
      .green
    }
  }
}

private struct AgentPromptToast: View {
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
      Text(
        "Agent prompt copied. Paste it into your coder agent or start an agent with that prompt."
      )
      .font(.caption)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    .frame(width: 300, alignment: .leading)
    .accessibilityIdentifier("AgentPromptToast")
  }
}

struct StatusBadge: View {
  @Environment(AppState.self) private var appState
  let status: SessionStatus

  var body: some View {
    Text(label)
      .font(.caption2)
      .fontWeight(.medium)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.15))
      .foregroundStyle(color)
      .clipShape(Capsule())
      .help(helpText)
  }

  private var label: String {
    switch status {
    case .awaitingReviewer: "Awaiting Review"
    case .awaitingAgent: "Awaiting Agent"
    case .approved: "Approved"
    case .closed: "Closed"
    }
  }

  private var color: Color {
    switch status {
    case .awaitingReviewer: .orange
    case .awaitingAgent: .blue
    case .approved: .green
    case .closed: .secondary
    }
  }

  private var helpText: String {
    switch status {
    case .awaitingReviewer:
      "Waiting for reviewer feedback."
    case .awaitingAgent:
      if appState.coderHandoffPendingFromWorkspace {
        "Waiting for the selected coder tab to connect to this review session."
      } else if appState.coderNeedsPromptHandoff {
        "Waiting for a coder agent to connect. Use Copy Agent Prompt to hand off the session."
      } else {
        "Waiting for the coder agent to respond to the current review feedback. \(appState.coderConnectionHelpText)"
      }
    case .approved:
      "The reviewer approved the current changes."
    case .closed:
      "The review session was closed."
    }
  }
}

struct DiffStatView: View {
  let files: [FileDiff]

  private var added: Int {
    files.reduce(0) { $0 + $1.addedCount }
  }

  private var removed: Int {
    files.reduce(0) { $0 + $1.removedCount }
  }

  var body: some View {
    if !files.isEmpty {
      HStack(spacing: 4) {
        Text("\(files.count) files")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text("+\(added)")
          .font(.caption2)
          .fontWeight(.medium)
          .foregroundColor(Color(nsColor: .systemGreen))
        Text("-\(removed)")
          .font(.caption2)
          .fontWeight(.medium)
          .foregroundColor(Color(nsColor: .systemRed))
        DiffStatBar(added: added, removed: removed)
      }
      .fixedSize()
    }
  }
}

struct DiffStatBar: View {
  let added: Int
  let removed: Int
  private let blockCount = 5
  private let blockSize: CGFloat = 8

  var body: some View {
    HStack(spacing: 1) {
      let total = added + removed
      let greenBlocks =
        total > 0
        ? max(0, min(blockCount, Int(round(Double(added) / Double(total) * Double(blockCount)))))
        : 0
      let redBlocks = total > 0 ? blockCount - greenBlocks : 0

      ForEach(0..<greenBlocks, id: \.self) { _ in
        RoundedRectangle(cornerRadius: 1)
          .fill(.green)
          .frame(width: blockSize, height: blockSize)
      }
      ForEach(0..<redBlocks, id: \.self) { _ in
        RoundedRectangle(cornerRadius: 1)
          .fill(.red)
          .frame(width: blockSize, height: blockSize)
      }
      if total == 0 {
        ForEach(0..<blockCount, id: \.self) { _ in
          RoundedRectangle(cornerRadius: 1)
            .fill(Color(nsColor: .separatorColor))
            .frame(width: blockSize, height: blockSize)
        }
      }
    }
  }
}
