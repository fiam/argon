import SwiftUI

enum ReviewHeaderActionPresentation {
  case full
  case compact
  case iconOnly
}

enum ReviewHeaderContentPresentation {
  case full
  case compact
  case minimal
}

struct SessionHeader: View {
  @Environment(AppState.self) private var appState
  let session: ReviewSession
  let fileCount: Int
  @State private var showSubmitSheet = false
  @State private var submitSummary = ""
  @State private var submitOutcome: String = "commented"
  @State private var showPromptToast = false
  @State private var promptToastMessage = AgentPromptToast.defaultMessage
  @State private var toastDismissWorkItem: DispatchWorkItem?
  @State private var hasShownExternalHandoffToast = false
  @State private var availableWidth: CGFloat = 0

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) {
        StatusBadge(status: session.status, presentation: contentPresentation)

        ModePicker(presentation: contentPresentation)

        DiffStatView(files: appState.files, presentation: contentPresentation)
      }

      if contentPresentation == .full, let summary = session.changeSummary {
        Divider().frame(height: 16)
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      // Reviewer agent decision banner
      if let decision = session.decision {
        Divider().frame(height: 16)
        DecisionBanner(decision: decision, presentation: contentPresentation)
      }

      Spacer()

      DiffModeToggle()

      if session.status != .approved && session.status != .closed {
        AgentLaunchButton(presentation: actionPresentation)
        if appState.showsCoderSetupActions {
          HandoffButton(presentation: actionPresentation) {
            showAgentPromptToast(externalHandoffToastMessage)
          }
        }
        CoderConnectionBadge(presentation: actionPresentation)
        Divider().frame(height: 16)
        reviewActions(presentation: actionPresentation)
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
    .background(Color(nsColor: .controlBackgroundColor))
    .background {
      GeometryReader { proxy in
        Color.clear
          .onAppear {
            availableWidth = proxy.size.width
          }
          .onChange(of: proxy.size.width) { _, newWidth in
            availableWidth = newWidth
          }
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if showPromptToast {
        AgentPromptToast(message: promptToastMessage)
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
      if appState.reviewLaunchContext == .externalHandoff,
        appState.coderConnectionState == .awaitingConnection,
        !hasShownExternalHandoffToast
      {
        hasShownExternalHandoffToast = true
        showAgentPromptToast(
          "Review prompt copied. Paste it into your external agent to connect the session."
        )
      }
    }
    .onDisappear {
      toastDismissWorkItem?.cancel()
      toastDismissWorkItem = nil
    }
  }

  private var externalHandoffToastMessage: String {
    if appState.reviewLaunchContext == .externalHandoff,
      appState.coderConnectionState == .awaitingConnection
    {
      return "Review prompt copied. Paste it into your external agent to connect the session."
    }
    return AgentPromptToast.defaultMessage
  }

  @ViewBuilder
  private func reviewActions(presentation: ReviewHeaderActionPresentation) -> some View {
    HStack(spacing: 8) {
      // Pending drafts badge
      if presentation == .full && !appState.pendingDrafts.isEmpty {
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
        switch presentation {
        case .full:
          Label("Submit Review", systemImage: "paperplane")
        case .compact:
          Label("Submit", systemImage: "paperplane")
        case .iconOnly:
          Image(systemName: "paperplane")
        }
      }
      .accessibilityIdentifier("submit-review-button")
      .accessibilityLabel("Submit Review")
      .controlSize(.small)
    }
  }

  private var actionPresentation: ReviewHeaderActionPresentation {
    let measuredWidth = availableWidth > 0 ? availableWidth : 980
    let reservedSummaryWidth: CGFloat = session.changeSummary == nil ? 0 : 170
    let reservedDecisionWidth: CGFloat = session.decision == nil ? 0 : 150
    let effectiveWidth = measuredWidth - reservedSummaryWidth - reservedDecisionWidth

    if effectiveWidth < 540 {
      return .iconOnly
    }
    if effectiveWidth < 620 {
      return .compact
    }
    return .full
  }

  private var contentPresentation: ReviewHeaderContentPresentation {
    let measuredWidth = availableWidth > 0 ? availableWidth : 980
    let remainingWidth = measuredWidth - estimatedTrailingControlsWidth

    if remainingWidth < 260 {
      return .minimal
    }
    if remainingWidth < 440 {
      return .compact
    }
    return .full
  }

  private var estimatedTrailingControlsWidth: CGFloat {
    let diffModeWidth: CGFloat = 74
    let basePadding: CGFloat = 48

    guard session.status != .approved && session.status != .closed else {
      return diffModeWidth + basePadding + 96
    }

    let reviewActionWidth: CGFloat
    switch actionPresentation {
    case .full:
      reviewActionWidth = appState.showsCoderSetupActions ? 520 : 220
    case .compact:
      reviewActionWidth = appState.showsCoderSetupActions ? 380 : 160
    case .iconOnly:
      reviewActionWidth = appState.showsCoderSetupActions ? 228 : 92
    }

    return diffModeWidth + basePadding + reviewActionWidth
  }

  private func showAgentPromptToast(_ message: String = AgentPromptToast.defaultMessage) {
    toastDismissWorkItem?.cancel()
    promptToastMessage = message
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
  let presentation: ReviewHeaderContentPresentation

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
        if presentation != .minimal {
          Text(activeModeLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
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
    switch presentation {
    case .full:
      switch appState.activeMode {
      case .branch:
        "\(shorten(appState.activeBaseRef))...\(shorten(appState.activeHeadRef))"
      case .commit:
        "commit \(shorten(appState.activeHeadRef))"
      case .uncommitted:
        "uncommitted changes"
      }
    case .compact, .minimal:
      switch appState.activeMode {
      case .branch:
        "branch"
      case .commit:
        "commit"
      case .uncommitted:
        "uncommitted"
      }
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

        FocusedTextEditor(
          text: $summary,
          onCommandReturn: onSubmit,
          accessibilityIdentifier: "submit-review-summary-editor"
        )
        .frame(width: 460, height: 70)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
      }

      // Actions
      HStack {
        HStack(spacing: 4) {
          Text("\u{2318}\u{23CE}")
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(nsColor: .separatorColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 3))
          Text("to submit")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        Button("Cancel", action: onCancel)
          .accessibilityIdentifier("submit-review-cancel-button")
          .keyboardShortcut(.cancelAction)
        Button {
          onSubmit()
        } label: {
          Label(submitLabel, systemImage: submitIcon)
        }
        .accessibilityIdentifier("submit-review-confirm-button")
        .keyboardShortcut(.return, modifiers: [.command])
        .buttonStyle(.borderedProminent)
        .tint(submitColor)
      }
    }
    .padding(24)
    .frame(width: 520)
    .accessibilityIdentifier("submit-review-sheet")
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
  let presentation: ReviewHeaderContentPresentation

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.caption)
      if presentation != .minimal {
        Text(label)
          .font(.caption)
          .fontWeight(.medium)
          .lineLimit(1)
      }
      if presentation == .full, let summary = decision.summary, !summary.isEmpty {
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
    .help(helpText)
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

  private var helpText: String {
    if let summary = decision.summary, !summary.isEmpty {
      return "\(label): \(summary)"
    }
    return label
  }
}

struct HandoffButton: View {
  @Environment(AppState.self) private var appState
  let presentation: ReviewHeaderActionPresentation
  let onCopy: () -> Void

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(appState.handoffPrompt, forType: .string)
      onCopy()
    } label: {
      switch presentation {
      case .full:
        HStack(spacing: 6) {
          Image(systemName: icon)
          Text(buttonLabel)
            .lineLimit(1)
        }
      case .compact:
        HStack(spacing: 6) {
          Image(systemName: icon)
          Text("Copy Prompt")
            .lineLimit(1)
        }
      case .iconOnly:
        Image(systemName: icon)
      }
    }
    .controlSize(.small)
    .fixedSize()
    .background(attentionBackground)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(attentionBorder)
    .help(helpText)
    .accessibilityIdentifier("CoderHandoffButton")
    .accessibilityLabel(buttonLabel)
  }

  private var icon: String {
    appState.coderNeedsPromptHandoff ? "bolt.badge.clock" : "doc.on.doc"
  }

  private var buttonLabel: String {
    if appState.reviewLaunchContext == .externalHandoff,
      appState.coderConnectionState == .awaitingConnection
    {
      return "Copy Prompt Again"
    }
    return "Copy Agent Prompt"
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
    if appState.reviewLaunchContext == .externalHandoff,
      appState.coderConnectionState == .awaitingConnection
    {
      return
        "The review prompt is already on your clipboard. Copy it again if needed, then paste it into your external agent."
    }
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
  let presentation: ReviewHeaderActionPresentation

  var body: some View {
    HStack(spacing: 6) {
      switch presentation {
      case .full:
        Circle()
          .fill(color)
          .frame(width: 7, height: 7)
        Text(appState.coderConnectionLabel)
          .lineLimit(1)
      case .compact:
        Circle()
          .fill(color)
          .frame(width: 7, height: 7)
        Text(compactLabel)
          .lineLimit(1)
      case .iconOnly:
        Image(systemName: statusIcon)
          .font(.caption2.weight(.semibold))
      }
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
    .accessibilityLabel(appState.coderConnectionLabel)
  }

  private var color: Color {
    switch appState.coderConnectionState {
    case .awaitingConnection:
      appState.coderHandoffPendingFromWorkspace ? .blue : .orange
    case .connected:
      .green
    }
  }

  private var compactLabel: String {
    switch appState.coderConnectionState {
    case .awaitingConnection:
      switch appState.reviewLaunchContext {
      case .coderHandoff:
        "Connecting"
      case .externalHandoff:
        "Paste"
      case .standalone:
        "No coder"
      }
    case .connected:
      "Connected"
    }
  }

  private var statusIcon: String {
    switch appState.coderConnectionState {
    case .awaitingConnection:
      "bolt.badge.clock"
    case .connected:
      "checkmark.circle.fill"
    }
  }
}

private struct AgentPromptToast: View {
  static let defaultMessage =
    "Agent prompt copied. Paste it into your coder agent or start an agent with that prompt."

  let message: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
      Text(message)
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
  let presentation: ReviewHeaderContentPresentation

  var body: some View {
    Group {
      if presentation == .minimal {
        Image(systemName: icon)
      } else {
        Text(label)
          .lineLimit(1)
      }
    }
    .font(.caption2)
    .fontWeight(.medium)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(color.opacity(0.15))
    .foregroundStyle(color)
    .clipShape(Capsule())
    .help(helpText)
  }

  private var label: String {
    switch presentation {
    case .full:
      switch status {
      case .awaitingReviewer: "Awaiting Review"
      case .awaitingAgent: "Awaiting Agent"
      case .approved: "Approved"
      case .closed: "Closed"
      }
    case .compact, .minimal:
      switch status {
      case .awaitingReviewer: "Review"
      case .awaitingAgent: "Agent"
      case .approved: "Approved"
      case .closed: "Closed"
      }
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

  private var icon: String {
    switch status {
    case .awaitingReviewer: "ellipsis.circle.fill"
    case .awaitingAgent: "bolt.circle.fill"
    case .approved: "checkmark.circle.fill"
    case .closed: "xmark.circle.fill"
    }
  }
}

struct DiffStatView: View {
  let files: [FileDiff]
  let presentation: ReviewHeaderContentPresentation

  private var added: Int {
    files.reduce(0) { $0 + $1.addedCount }
  }

  private var removed: Int {
    files.reduce(0) { $0 + $1.removedCount }
  }

  var body: some View {
    if !files.isEmpty {
      HStack(spacing: 4) {
        if presentation == .full {
          Text("\(files.count) files")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if presentation != .minimal {
          Text("+\(added)")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(Color(nsColor: .systemGreen))
          Text("-\(removed)")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(Color(nsColor: .systemRed))
        }

        if presentation != .minimal {
          DiffStatBar(added: added, removed: removed)
        }
      }
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
