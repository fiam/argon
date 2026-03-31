import AppKit
import SwiftTerm
import SwiftUI
import UserNotifications

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
    // cd to repo root before running the agent command
    let cdAndRun = "cd \(shellQuote(agent.repoRoot)) && \(agent.fullCommand)"
    let args = ["-l", "-c", cdAndRun]
    termView.startProcess(
      executable: shell,
      args: args,
      environment: buildEnvironment(),
      execName: nil
    )

    return termView
  }

  func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(agent: agent)
  }

  private func shellQuote(_ s: String) -> String {
    "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
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

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 5) {
        Circle()
          .fill(agent.isRunning ? .green : .secondary)
          .frame(width: 6, height: 6)
        Text(agent.nickname)
          .font(.caption)
          .fontWeight(isSelected ? .medium : .regular)
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
