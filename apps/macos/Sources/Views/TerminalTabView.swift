import AppKit
import SwiftTerm
import SwiftUI
import UserNotifications

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

// MARK: - Terminal View (NSViewRepresentable wrapping SwiftTerm)

struct AgentTerminalView: NSViewRepresentable {
  let agent: ReviewerAgentInstance

  func makeNSView(context: Context) -> LocalProcessTerminalView {
    let termView = LocalProcessTerminalView(frame: .zero)
    termView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    termView.nativeForegroundColor = .textColor
    termView.nativeBackgroundColor = .textBackgroundColor
    termView.processDelegate = context.coordinator

    let shell = "/bin/zsh"
    let args = ["-l", "-c", agent.fullCommand]
    termView.startProcess(
      executable: shell,
      args: args,
      environment: buildEnvironment(),
      execName: nil,
      currentDirectory: agent.repoRoot
    )

    return termView
  }

  func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(agent: agent)
  }

  private func buildEnvironment() -> [String] {
    var env = ProcessInfo.processInfo.environment
    env["ARGON_SESSION_ID"] = agent.sessionId
    env["ARGON_REPO_ROOT"] = agent.repoRoot
    if let cliCmd = ProcessInfo.processInfo.environment["ARGON_CLI_CMD"] {
      env["ARGON_CLI_CMD"] = cliCmd
    }
    env["TERM"] = "xterm-256color"
    return env.map { "\($0.key)=\($0.value)" }
  }

  class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
    let agent: ReviewerAgentInstance

    init(agent: ReviewerAgentInstance) {
      self.agent = agent
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
      let agent = self.agent
      Task { @MainActor in
        agent.isRunning = false
      }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  }
}

// MARK: - Reviewer Agent Tabs Panel

struct ReviewerAgentTabsView: View {
  @Environment(AppState.self) private var appState
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

        // Terminal content
        if let agent = appState.reviewerAgents.first(where: { $0.id == effectiveSelectedId }) {
          AgentTerminalView(agent: agent)
            .id(agent.id)
        }
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
