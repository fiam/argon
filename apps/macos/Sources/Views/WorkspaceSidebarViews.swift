import AppKit
import SwiftUI

func workspaceSidebarAccessibilityIdentifier(for path: String) -> String {
  let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
    (partial ^ UInt64(byte)) &* 1_099_511_628_211
  }
  let lastComponent = URL(fileURLWithPath: path).lastPathComponent
  return "workspace-sidebar-row-\(lastComponent)-\(String(hash, radix: 16))"
}

struct WorkspaceSidebar: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @State private var showNewWorktreeSheet = false

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        if workspaceState.worktrees.isEmpty && workspaceState.isLoading {
          Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspaceState.worktrees.isEmpty {
          ContentUnavailableView(
            "No Worktrees",
            systemImage: "square.stack.3d.up.slash",
            description: Text("Open a Git repository to populate the workspace.")
          )
        } else {
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(workspaceState.worktrees) { worktree in
                WorkspaceSidebarRow(
                  worktree: worktree,
                  isSelected: workspaceState.selectedWorktree?.path == worktree.path
                ) {
                  workspaceState.selectWorktree(path: worktree.path)
                }
              }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 10)
          }
          .scrollIndicators(.hidden)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .navigationTitle("Worktrees")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showNewWorktreeSheet = true
        } label: {
          Image(systemName: "plus")
        }
        .help("Create a new worktree")
        .accessibilityIdentifier("workspace-new-worktree-button")
      }
    }
    .sheet(isPresented: $showNewWorktreeSheet) {
      WorkspaceNewWorktreeSheet(isPresented: $showNewWorktreeSheet)
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(width: 0.5)
    }
    .clipped()
  }
}

struct WorkspaceSidebarRow: View {
  @Environment(WorkspaceState.self) private var workspaceState
  let worktree: DiscoveredWorktree
  let isSelected: Bool
  let onSelect: () -> Void
  @State private var isHovering = false

  var body: some View {
    ZStack(alignment: .trailing) {
      Button(action: onSelect) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(worktree.displayName)
              .font(.body.weight(.semibold))
              .lineLimit(1)
              .truncationMode(.middle)
              .layoutPriority(1)
              .accessibilityIdentifier("workspace-sidebar-worktree-name")

            if worktree.isBaseWorktree {
              WorkspaceBadge(label: "Base", tint: Color(nsColor: .controlAccentColor))
            }

            Spacer(minLength: 0)
          }

          WorkspaceSidebarMetadataLine(
            summary: summary,
            tokens: metadataTokens
          )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .padding(.trailing, hoverActionsReservedWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(rowBackground)
        )
        .overlay {
          if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(workspaceSidebarAccessibilityIdentifier(for: worktree.path))

      WorkspaceSidebarHoverActions(
        worktree: worktree,
        isVisible: isHovering
      )
      .padding(.trailing, 8)
    }
    .onHover { hovering in
      isHovering = hovering
    }
  }

  private var hoverActionsReservedWidth: CGFloat {
    worktree.isBaseWorktree ? 36 : 68
  }

  private var rowBackground: Color {
    if isSelected {
      return Color.accentColor.opacity(0.14)
    }

    return isHovering ? Color.primary.opacity(0.05) : .clear
  }

  private var summary: WorktreeDiffSummary {
    workspaceState.summary(for: worktree.path)
  }

  private var hasConflicts: Bool {
    workspaceState.hasConflicts(for: worktree.path)
  }

  private var needsAttention: Bool {
    workspaceState.worktreeNeedsAttention(for: worktree.path)
  }

  private var isMergeBackCompleted: Bool {
    workspaceState.isMergeBackCompleted(for: worktree.path)
  }

  private var activeAgentCount: Int {
    workspaceState.activeAgentCount(for: worktree.path)
  }

  private var agentActivitySummary: WorktreeAgentActivitySummary {
    workspaceState.agentActivitySummary(for: worktree.path)
  }

  private var waitingForHumanAgentActivity: WorkspaceSidebarAgentActivityKind? {
    guard agentActivitySummary.waitingForHumanCount > 0 else { return nil }
    return .needsInput(count: agentActivitySummary.waitingForHumanCount)
  }

  private var workingAgentActivity: WorkspaceSidebarAgentActivityKind? {
    guard agentActivitySummary.waitingForHumanCount == 0 else { return nil }
    if agentActivitySummary.thinkingCount > 0 {
      return .thinking(count: agentActivitySummary.thinkingCount)
    }
    if activeAgentCount > 0 {
      return .active(count: activeAgentCount)
    }
    return nil
  }

  private var reviewSnapshot: WorkspaceReviewSnapshot? {
    workspaceState.reviewSnapshot(for: worktree.path)
  }

  private var reviewStatusLabel: String? {
    guard let reviewSnapshot else { return nil }
    switch reviewSnapshot.status {
    case .awaitingReviewer:
      return "awaiting review"
    case .awaitingAgent:
      return "awaiting agent"
    case .approved:
      return "approved"
    case .closed:
      return "closed"
    }
  }

  private var reviewStatusTint: Color {
    guard let reviewSnapshot else { return .secondary }
    switch reviewSnapshot.status {
    case .awaitingReviewer:
      return .orange
    case .awaitingAgent:
      return .blue
    case .approved:
      return .green
    case .closed:
      return .secondary
    }
  }

  private var metadataTokens: [WorkspaceSidebarMetadataToken] {
    var tokens: [WorkspaceSidebarMetadataToken] = []

    if let branchLabel = worktree.branchLabel {
      tokens.append(
        WorkspaceSidebarMetadataToken(
          id: "branch",
          label: branchLabel,
          compactLabel: branchLabel,
          symbolName: "arrow.triangle.branch",
          tint: .secondary,
          accessibilityIdentifier: "workspace-sidebar-branch"
        )
      )
    }

    if let stateLabel = worktree.stateLabel {
      tokens.append(
        WorkspaceSidebarMetadataToken(
          id: "worktree-state",
          label: stateLabel,
          compactLabel: stateLabel,
          symbolName: nil,
          tint: .secondary,
          accessibilityIdentifier: "workspace-sidebar-worktree-state"
        )
      )
    }

    if let reviewStatusLabel {
      tokens.append(
        WorkspaceSidebarMetadataToken(
          id: "review-status",
          label: reviewStatusLabel,
          compactLabel: reviewStatusCompactLabel,
          symbolName: nil,
          tint: reviewStatusTint,
          accessibilityIdentifier: "workspace-sidebar-review-status"
        )
      )
    }

    if isMergeBackCompleted {
      tokens.append(
        WorkspaceSidebarMetadataToken(
          id: "merge-back-complete",
          label: "done",
          compactLabel: "done",
          symbolName: "checkmark.circle.fill",
          tint: .green,
          accessibilityIdentifier: "workspace-sidebar-merge-back-complete"
        )
      )
    } else if let waitingForHumanAgentActivity {
      tokens.append(.agent(waitingForHumanAgentActivity))
    } else if needsAttention {
      tokens.append(
        WorkspaceSidebarMetadataToken(
          id: "needs-attention",
          label: "needs attention",
          compactLabel: "attention",
          symbolName: "exclamationmark.circle.fill",
          tint: .orange,
          accessibilityIdentifier: "workspace-sidebar-needs-attention"
        )
      )
    }

    if hasConflicts {
      tokens.append(
        WorkspaceSidebarMetadataToken(
          id: "conflicts",
          label: "conflicts",
          compactLabel: "conflict",
          symbolName: "exclamationmark.triangle.fill",
          tint: .orange,
          accessibilityIdentifier: "workspace-sidebar-conflicts"
        )
      )
    }

    if let workingAgentActivity {
      tokens.append(.agent(workingAgentActivity))
    }

    return tokens
  }

  private var reviewStatusCompactLabel: String {
    guard let reviewSnapshot else { return "" }
    switch reviewSnapshot.status {
    case .awaitingReviewer:
      return "review"
    case .awaitingAgent:
      return "agent"
    case .approved:
      return "approved"
    case .closed:
      return "closed"
    }
  }
}

struct WorkspaceSidebarMetadataToken: Identifiable {
  let id: String
  let label: String
  let compactLabel: String
  let symbolName: String?
  let tint: Color
  var animatesSymbol = false
  let accessibilityIdentifier: String

  static func agent(_ kind: WorkspaceSidebarAgentActivityKind)
    -> WorkspaceSidebarMetadataToken
  {
    WorkspaceSidebarMetadataToken(
      id: kind.accessibilityIdentifier,
      label: kind.sidebarLabel,
      compactLabel: kind.compactSidebarLabel,
      symbolName: kind.symbolName,
      tint: kind.tint,
      animatesSymbol: kind.animatesSymbol,
      accessibilityIdentifier: kind.accessibilityIdentifier
    )
  }
}

struct WorkspaceSidebarMetadataLine: View {
  let summary: WorktreeDiffSummary
  let tokens: [WorkspaceSidebarMetadataToken]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      metadataLine(label: \.label)
      metadataLine(label: \.compactLabel)
      metadataIconLine
      summaryLine
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var summaryLine: some View {
    HStack(spacing: 8) {
      WorkspaceCompactDiffSummary(
        summary: summary,
        showsBar: false,
        usesCompactNumbers: true
      )
    }
    .fixedSize(horizontal: true, vertical: true)
  }

  private func metadataLine(
    label: KeyPath<WorkspaceSidebarMetadataToken, String>
  ) -> some View {
    HStack(spacing: 8) {
      WorkspaceCompactDiffSummary(
        summary: summary,
        showsBar: false,
        usesCompactNumbers: true
      )
      if !tokens.isEmpty {
        tokenRow(tokens, label: label)
      }
    }
    .fixedSize(horizontal: true, vertical: true)
  }

  private var metadataIconLine: some View {
    HStack(spacing: 8) {
      WorkspaceCompactDiffSummary(
        summary: summary,
        showsBar: false,
        usesCompactNumbers: true
      )
      if !tokens.isEmpty {
        WorkspaceSidebarMetadataIconStrip(tokens: tokens)
      }
    }
    .fixedSize(horizontal: true, vertical: true)
  }

  private func tokenRow(
    _ tokens: [WorkspaceSidebarMetadataToken],
    label: KeyPath<WorkspaceSidebarMetadataToken, String>
  ) -> some View {
    HStack(spacing: 8) {
      ForEach(tokens) { token in
        WorkspaceSidebarMetadataItem(
          label: token[keyPath: label],
          symbolName: token.symbolName,
          symbolTint: token.tint,
          animatesSymbol: token.animatesSymbol,
          accessibilityIdentifier: token.accessibilityIdentifier
        )
      }
    }
    .fixedSize(horizontal: true, vertical: true)
  }
}

struct WorkspaceSidebarMetadataItem: View {
  let label: String
  var symbolName: String? = nil
  var symbolTint: Color? = nil
  var animatesSymbol = false
  var accessibilityIdentifier: String? = nil

  var body: some View {
    HStack(spacing: 4) {
      if let symbolName {
        WorkspaceSidebarMetadataSymbol(
          symbolName: symbolName,
          tint: symbolTint ?? .secondary,
          animates: animatesSymbol,
          fontSize: 9,
          frameSize: 10
        )
        .accessibilityHidden(true)
      } else if let symbolTint {
        Circle()
          .fill(symbolTint)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
      }

      Text(label)
        .lineLimit(1)
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(label))
    .accessibilityIdentifier(accessibilityIdentifier ?? "")
  }
}

struct WorkspaceSidebarMetadataIconStrip: View {
  let tokens: [WorkspaceSidebarMetadataToken]

  var body: some View {
    HStack(spacing: 5) {
      ForEach(tokens) { token in
        if let symbolName = token.symbolName {
          WorkspaceSidebarMetadataSymbol(
            symbolName: symbolName,
            tint: token.tint,
            animates: token.animatesSymbol,
            fontSize: 9,
            frameSize: 10
          )
          .help(token.label)
          .accessibilityLabel(Text(token.label))
          .accessibilityIdentifier(token.accessibilityIdentifier)
        } else {
          Circle()
            .fill(token.tint)
            .frame(width: 6, height: 6)
            .frame(width: 10, height: 10)
            .help(token.label)
            .accessibilityLabel(Text(token.label))
            .accessibilityIdentifier(token.accessibilityIdentifier)
        }
      }
    }
    .fixedSize(horizontal: true, vertical: true)
  }
}

struct WorkspaceSidebarMetadataSymbol: View {
  let symbolName: String
  let tint: Color
  let animates: Bool
  let fontSize: CGFloat
  let frameSize: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if animates && !reduceMotion {
        TimelineView(.animation) { context in
          symbol(intensity: pulseIntensity(at: context.date))
        }
      } else {
        symbol(intensity: 1)
      }
    }
    .frame(width: frameSize, height: frameSize)
  }

  private func symbol(intensity: Double) -> some View {
    Image(systemName: symbolName)
      .font(.system(size: fontSize, weight: .semibold))
      .foregroundStyle(tint.opacity(0.62 + (0.38 * intensity)))
      .scaleEffect(0.94 + (0.08 * intensity))
  }

  private func pulseIntensity(at date: Date) -> Double {
    let period = 1.8
    let phase =
      date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
      / period
    return (sin(phase * 2 * .pi) + 1) / 2
  }
}

enum WorkspaceSidebarAgentActivityKind: Equatable {
  case needsInput(count: Int)
  case thinking(count: Int)
  case active(count: Int)

  var symbolName: String {
    switch self {
    case .needsInput:
      "exclamationmark.circle.fill"
    case .thinking:
      "sparkles"
    case .active:
      "sparkles.rectangle.stack"
    }
  }

  var tint: Color {
    switch self {
    case .needsInput:
      .orange
    case .thinking:
      Color(nsColor: .controlAccentColor)
    case .active:
      .secondary
    }
  }

  var sidebarLabel: String {
    switch self {
    case .needsInput(let count):
      count == 1 ? "1 waiting" : "\(count) waiting"
    case .thinking(let count):
      count == 1 ? "1 working" : "\(count) working"
    case .active(let count):
      count == 1 ? "1 agent" : "\(count) agents"
    }
  }

  var compactSidebarLabel: String {
    switch self {
    case .needsInput:
      "waiting"
    case .thinking:
      "working"
    case .active(let count):
      count == 1 ? "agent" : "\(count) agents"
    }
  }

  var animatesSymbol: Bool {
    if case .thinking = self {
      return true
    }
    return false
  }

  var accessibilityIdentifier: String {
    switch self {
    case .needsInput:
      "workspace-sidebar-agent-needs-input"
    case .thinking:
      "workspace-sidebar-agent-thinking"
    case .active:
      "workspace-sidebar-agent-active"
    }
  }
}
