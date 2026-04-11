import AppKit
import SwiftUI

enum AgentReviewState {
  case running
  case reviewing
  case commented
  case changesRequested
  case stopped

  var color: SwiftUI.Color {
    switch self {
    case .running: .green
    case .reviewing: .blue
    case .commented: .blue
    case .changesRequested: .orange
    case .stopped: .secondary
    }
  }

  var label: String {
    switch self {
    case .running: "reviewing"
    case .reviewing: "reviewing"
    case .commented: "commented"
    case .changesRequested: "changes"
    case .stopped: "done"
    }
  }
}

struct AgentTerminalView: View {
  let agent: ReviewerAgentInstance
  var terminalFontSize: CGFloat = 12

  var body: some View {
    GhosttyTerminalView(agent: agent, terminalFontSize: terminalFontSize)
  }
}

// MARK: - Reviewer Agent Tabs Panel

struct ReviewerAgentTabsView: View {
  @Environment(AppState.self) private var appState
  @AppStorage("terminalFontSize") private var terminalFontSize = 12.0
  @State private var selectedAgentId: UUID?

  var body: some View {
    if appState.reviewerAgents.isEmpty {
      EmptyStateView(
        icon: "person.2",
        title: "No reviewer agents",
        detail: "Launch a reviewer agent to get automated feedback."
      )
    } else {
      VStack(spacing: 0) {
        // Tab bar
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 2) {
            ForEach(appState.reviewerAgents) { agent in
              AgentTab(agent: agent, isSelected: effectiveSelectedId == agent.id) {
                selectedAgentId = agent.id
              }
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
        }
        .background(Color(nsColor: .controlBackgroundColor))

        Divider()

        // Terminal content – keep all terminals alive in a ZStack so
        // switching tabs doesn't destroy the NSView (and kill the process).
        // Hide inactive terminals with zero opacity so Ghostty background
        // transparency can't bleed older tabs through the selected one.
        ZStack {
          ForEach(appState.reviewerAgents) { agent in
            let isSelected = effectiveSelectedId == agent.id
            AgentTerminalView(agent: agent, terminalFontSize: terminalFontSize)
              .id(agent.id)
              .zIndex(isSelected ? 1 : 0)
              .opacity(isSelected ? 1 : 0)
              .allowsHitTesting(isSelected)
              .accessibilityHidden(!isSelected)
          }
        }
      }
      .accessibilityIdentifier("reviewer-agent-tabs")
      .onAppear {
        UITestAutomationSignal.write(
          "reviewer-tabs-appeared",
          to: UITestAutomationConfig.current().signalFilePath
        )
      }
    }
  }

  private var effectiveSelectedId: UUID? {
    if let sel = selectedAgentId,
      appState.reviewerAgents.contains(where: { $0.id == sel })
    {
      return sel
    }
    return appState.reviewerAgents.first?.id
  }
}

struct AgentTab: View {
  @Environment(AppState.self) private var appState
  let agent: ReviewerAgentInstance
  let isSelected: Bool
  let onSelect: () -> Void

  private var agentState: AgentReviewState {
    if !agent.isRunning { return .stopped }
    if let decision = agent.lastDecision {
      switch decision {
      case "changes_requested": return .changesRequested
      case "commented": return .commented
      default: return .commented
      }
    }
    if agent.hasComments { return .reviewing }
    return .running
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 5) {
        Circle()
          .fill(agentState.color)
          .frame(width: 6, height: 6)
        Text(agent.nickname)
          .font(.caption)
          .fontWeight(isSelected ? .medium : .regular)
        if agentState != .running && agentState != .stopped {
          Text(agentState.label)
            .font(.system(size: 8))
            .foregroundStyle(agentState.color)
        }
        Text("(\(agent.profile.name))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Button {
          appState.stopReviewerAgent(agent.id)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    .buttonStyle(.plain)
  }
}
