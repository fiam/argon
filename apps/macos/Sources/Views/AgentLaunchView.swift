import SwiftUI

struct AgentLaunchButton: View {
  @Environment(AppState.self) private var appState
  @State private var showLaunchSheet = false

  var body: some View {
    Button {
      showLaunchSheet = true
    } label: {
      Label("Launch Reviewer", systemImage: "person.badge.plus")
    }
    .accessibilityIdentifier("launch-reviewer-button")
    .controlSize(.small)
    .disabled(appState.session?.status == .approved || appState.session?.status == .closed)
    .sheet(isPresented: $showLaunchSheet) {
      AgentLaunchSheet(isPresented: $showLaunchSheet)
    }
  }
}

struct AgentLaunchSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(SavedAgentProfiles.self) private var savedAgents
  @Environment(AgentAvailability.self) private var agentAvailability
  @Binding var isPresented: Bool
  @State private var selectedAgentId: String?
  @State private var yoloMode = false
  @State private var sandboxEnabled = false
  @State private var showSandboxHelp = false
  @State private var sandboxHelp: SandboxHelpData?
  @State private var sandboxHelpError: String?
  @State private var sandboxHelpLoading = false
  @State private var focusPrompt = ""
  @State private var customCommand = ""
  @State private var useCustom = false

  private var selectedSavedAgent: SavedAgentProfile? {
    guard let id = selectedAgentId else { return nil }
    return savedAgents.profiles.first { $0.id == id }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      // Header
      HStack(spacing: 10) {
        Image(systemName: "person.badge.plus")
          .font(.title)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("Launch Reviewer Agent")
            .font(.title2)
            .fontWeight(.semibold)
          Text("The agent will review the current diff and post comments.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      // Agent picker
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text("Agent")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
          if agentAvailability.hasPendingCommands {
            ProgressView()
              .controlSize(.small)
            Text("Checking commands…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 6) {
          ForEach(savedAgents.profiles) { profile in
            let status = agentAvailability.status(for: profile)
            AgentPickerCard(
              profile: profile,
              status: status,
              isSelected: !useCustom && selectedAgentId == profile.id
            ) {
              selectedAgentId = profile.id
              useCustom = false
              // Reset yolo if this agent doesn't support it
              if profile.yoloFlag.isEmpty {
                yoloMode = false
              }
            }
          }

          // Custom command card
          Button {
            useCustom = true
            selectedAgentId = nil
            yoloMode = false
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "terminal")
                .foregroundStyle(useCustom ? .purple : .secondary)
              Text("Custom")
                .fontWeight(useCustom ? .medium : .regular)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
              useCustom ? Color.purple.opacity(0.12) : Color(nsColor: .controlBackgroundColor)
            )
            .foregroundStyle(useCustom ? .purple : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .stroke(
                  useCustom ? Color.purple.opacity(0.4) : Color(nsColor: .separatorColor),
                  lineWidth: 1)
            )
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("agent-launch-custom-button")
        }

        if useCustom {
          TextField("Command (e.g. claude --dangerously-skip-permissions)", text: $customCommand)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .accessibilityIdentifier("agent-launch-custom-command-field")
        }

        // YOLO toggle (only for agents that support it)
        if let agent = selectedSavedAgent, !agent.yoloFlag.isEmpty {
          Toggle(isOn: $yoloMode) {
            VStack(alignment: .leading, spacing: 1) {
              Text("Auto-approve mode")
                .font(.callout)
              Text("Appends \(agent.yoloFlag) to the command")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .toggleStyle(.checkbox)
        }
      }

      // Focus prompt
      VStack(alignment: .leading, spacing: 6) {
        Text("Focus (optional)")
          .font(.callout)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)
        TextField(
          "e.g. check error handling, verify test coverage...",
          text: $focusPrompt
        )
        .textFieldStyle(.roundedBorder)
      }

      VStack(alignment: .leading, spacing: 4) {
        Toggle(isOn: $sandboxEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Sandboxed")
              .font(.callout)
            Text("Repo and Argon session storage stay writable.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.checkbox)

        Button("Config syntax and current defaults") {
          presentSandboxHelp()
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.leading, 22)
        .popover(isPresented: $showSandboxHelp, arrowEdge: .bottom) {
          SandboxHelpPopover(
            help: sandboxHelp,
            errorMessage: sandboxHelpError,
            isLoading: sandboxHelpLoading
          )
        }
      }

      // Actions
      HStack {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        .accessibilityIdentifier("agent-launch-cancel-button")
        .keyboardShortcut(.cancelAction)

        Button("Launch") {
          launch()
        }
        .accessibilityIdentifier("agent-launch-confirm-button")
        .keyboardShortcut(.defaultAction)
        .disabled(!canLaunch)
      }
    }
    .padding(24)
    .frame(width: 500)
    .accessibilityIdentifier("agent-launch-sheet")
    .onAppear {
      agentAvailability.refresh(for: savedAgents.profiles)
      syncSelectedAgent()
    }
    .onChange(of: savedAgents.profiles) { _, _ in
      agentAvailability.refresh(for: savedAgents.profiles)
      syncSelectedAgent()
    }
    .onChange(of: agentAvailability.revision) { _, _ in
      syncSelectedAgent()
    }
  }

  private var canLaunch: Bool {
    if useCustom {
      return !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let saved = selectedSavedAgent else { return false }
    return agentAvailability.status(for: saved) == .available
  }

  private func launch() {
    let profile: AgentProfile
    if useCustom {
      let cmd = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
      profile = AgentProfile(
        id: "custom-\(UUID().uuidString.prefix(8))",
        name: "Custom",
        command: cmd,
        icon: "terminal",
        isDetected: false
      )
    } else if let saved = selectedSavedAgent {
      let cmd = saved.fullCommand(yolo: yoloMode, sandboxed: sandboxEnabled)
      profile = AgentProfile(
        id: saved.id,
        name: yoloMode ? "\(saved.name) (YOLO)" : saved.name,
        command: cmd,
        icon: saved.icon,
        isDetected: true
      )
    } else {
      return
    }

    let focus = focusPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    appState.launchReviewerAgent(
      profile: profile,
      focusPrompt: focus.isEmpty ? nil : focus,
      sandboxEnabled: sandboxEnabled
    )
    isPresented = false
  }

  private func presentSandboxHelp() {
    showSandboxHelp = true
    guard !sandboxHelpLoading else { return }
    if sandboxHelp?.repoRoot == appState.repoRoot, sandboxHelpError == nil {
      return
    }

    let repoRoot = appState.repoRoot
    sandboxHelpLoading = true
    sandboxHelpError = nil

    Task {
      let result = await Task.detached(priority: .userInitiated) {
        Result {
          let defaults = try ArgonCLI.sandboxDefaults(repoRoot: repoRoot)
          let paths = try ArgonCLI.sandboxConfigPaths(repoRoot: repoRoot)
          return SandboxHelpData(repoRoot: repoRoot, defaults: defaults, paths: paths)
        }
      }.value

      sandboxHelpLoading = false
      switch result {
      case .success(let help):
        sandboxHelp = help
        sandboxHelpError = nil
      case .failure(let error):
        sandboxHelp = nil
        sandboxHelpError = error.localizedDescription
      }
    }
  }

  private func syncSelectedAgent() {
    guard !useCustom else { return }

    if let selectedAgentId,
      let selected = savedAgents.profiles.first(where: { $0.id == selectedAgentId }),
      agentAvailability.status(for: selected) != .unavailable
    {
      return
    }

    if let available = savedAgents.profiles.first(where: {
      agentAvailability.status(for: $0) == .available
    }) {
      selectedAgentId = available.id
      return
    }

    selectedAgentId = savedAgents.profiles.first?.id
  }
}

private struct SandboxHelpData: Sendable {
  let repoRoot: String?
  let defaults: ArgonCLI.SandboxDefaults
  let paths: ArgonCLI.SandboxConfigPaths
}

private struct SandboxHelpPopover: View {
  let help: SandboxHelpData?
  let errorMessage: String?
  let isLoading: Bool

  private var platformLabel: String {
    "macOS"
  }

  private var configExample: String {
    """
    include_defaults: true
    write_roots:
      - .direnv
      - .build
    write_paths:
      - /dev/null

    macos:
      write_roots:
        - .swiftpm
    """
  }

  private var commandExamples: String {
    """
    argon sandbox defaults
    argon sandbox config paths --repo <repo>
    argon sandbox config add-write-root --scope repo .direnv
    argon sandbox config add-write-root --scope user ~/.cache
    """
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Sandbox configuration")
            .font(.headline)
          Text(
            "Sandboxed reviewer agents can write to the repo, the Argon session directory, the built-in defaults below, and any extra paths you add in sandbox config files."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
          Text("Config files")
            .font(.subheadline)
            .fontWeight(.semibold)

          if let help {
            SandboxPathRow(
              label: "Repo",
              value: help.paths.repoExistingPath ?? help.paths.repoDefaultPath ?? "Unavailable"
            )
            SandboxPathRow(
              label: "User",
              value: help.paths.userExistingPath ?? help.paths.userDefaultPath
            )
          } else if isLoading {
            ProgressView()
              .controlSize(.small)
          } else if let errorMessage {
            Text(errorMessage)
              .font(.caption)
              .foregroundStyle(.red)
          }

          Text("Only one config file per scope is allowed: `.yaml`, `.yml`, `.toml`, or `.json`.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(
            "Repo config paths may be relative to the repo root. User config paths must be absolute."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("YAML syntax")
            .font(.subheadline)
            .fontWeight(.semibold)
          SandboxCodeBlock(text: configExample)
          Text(
            "Use `include_defaults: false` to replace the built-in defaults instead of extending them."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("CLI")
            .font(.subheadline)
            .fontWeight(.semibold)
          SandboxCodeBlock(text: commandExamples)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Built-in defaults on \(platformLabel)")
            .font(.subheadline)
            .fontWeight(.semibold)

          if let help {
            if !help.defaults.writablePaths.isEmpty {
              Text("Exact paths")
                .font(.caption)
                .foregroundStyle(.secondary)
              SandboxDefaultsList(values: help.defaults.writablePaths)
            }

            if !help.defaults.writableRoots.isEmpty {
              Text("Writable roots")
                .font(.caption)
                .foregroundStyle(.secondary)
              SandboxDefaultsList(values: help.defaults.writableRoots)
            }
          } else if isLoading {
            ProgressView()
              .controlSize(.small)
          } else if let errorMessage {
            Text(errorMessage)
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
      }
      .padding(16)
    }
    .frame(width: 460, height: 440)
  }
}

private struct SandboxPathRow: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
  }
}

private struct SandboxCodeBlock: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(.caption, design: .monospaced))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .textSelection(.enabled)
  }
}

private struct SandboxDefaultsList: View {
  let values: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(values, id: \.self) { value in
        Text(value)
          .font(.system(.caption, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .textSelection(.enabled)
      }
    }
  }
}

struct AgentPickerCard: View {
  let profile: SavedAgentProfile
  let status: AgentAvailability.Status
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 6) {
        AgentIconView(icon: profile.icon)
          .foregroundStyle(isSelected ? .blue : .secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(profile.name)
            .fontWeight(isSelected ? .medium : .regular)
            .lineLimit(1)
          if status != .available {
            Text(statusLabel)
              .font(.system(size: 9))
              .foregroundStyle(statusColor)
          }
        }
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity)
      .background(isSelected ? Color.blue.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
      .foregroundStyle(isSelected ? .blue : status == .available ? .primary : .secondary)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isSelected ? Color.blue.opacity(0.4) : Color(nsColor: .separatorColor), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .opacity(status == .unavailable ? 0.55 : 1)
  }

  private var statusLabel: String {
    switch status {
    case .checking:
      "checking..."
    case .available:
      ""
    case .unavailable:
      "not installed"
    }
  }

  private var statusColor: Color {
    switch status {
    case .checking:
      .secondary
    case .available:
      .primary
    case .unavailable:
      .orange
    }
  }
}
