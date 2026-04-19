import SwiftUI

enum AgentPickerLayout {
  static let gridMinimumWidth: CGFloat = 140
}

struct AgentLaunchButton: View {
  @Environment(AppState.self) private var appState
  let presentation: ReviewHeaderActionPresentation
  @State private var showLaunchSheet = false

  init(presentation: ReviewHeaderActionPresentation = .full) {
    self.presentation = presentation
  }

  var body: some View {
    Button {
      showLaunchSheet = true
    } label: {
      switch presentation {
      case .full:
        Label("Launch Reviewer", systemImage: "person.badge.plus")
      case .compact:
        Label("Reviewer", systemImage: "person.badge.plus")
      case .iconOnly:
        Image(systemName: "person.badge.plus")
      }
    }
    .accessibilityIdentifier("launch-reviewer-button")
    .accessibilityLabel("Launch Reviewer")
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
  @State private var yoloMode = true
  @State private var sandboxEnabled = true
  @State private var showSandboxHelp = false
  @State private var sandboxHelp: SandboxHelpData?
  @State private var sandboxHelpError: String?
  @State private var sandboxHelpLoading = false
  @State private var focusPrompt = ""
  @State private var customCommand = ""
  @State private var useCustom = false
  @State private var isLaunching = false
  @State private var pendingSandboxfilePrompt: SandboxfilePromptRequest?
  @State private var pendingLaunchProfile: AgentProfile?
  @State private var pendingLaunchFocusPrompt: String?

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

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: AgentPickerLayout.gridMinimumWidth))], spacing: 6
        ) {
          ForEach(savedAgents.profiles) { profile in
            savedAgentCard(for: profile)
          }

          // Custom command card
          CustomAgentPickerCard(isSelected: useCustom, accentColor: .purple) {
            useCustom = true
            selectedAgentId = nil
            yoloMode = false
          }
          .accessibilityIdentifier("agent-launch-custom-button")
        }

        if useCustom {
          TextField("Command (e.g. claude --dangerously-skip-permissions)", text: $customCommand)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .accessibilityIdentifier("agent-launch-custom-command-field")
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Toggle(isOn: $sandboxEnabled) {
          Text("Sandboxed")
            .font(.callout)
        }
        .toggleStyle(.checkbox)

        Button("Configuration") {
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

      // YOLO toggle (only for agents that support it)
      if let agent = selectedSavedAgent, !agent.yoloFlag.isEmpty {
        Toggle(isOn: $yoloMode) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Auto-approve mode")
              .font(.callout)
            Text(yoloSubtitle(for: agent.yoloFlag))
              .font(.caption)
              .foregroundStyle(yoloSubtitleColor)
          }
        }
        .toggleStyle(.checkbox)
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

      // Actions
      HStack {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        .accessibilityIdentifier("agent-launch-cancel-button")
        .keyboardShortcut(.cancelAction)
        .disabled(isLaunching)

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
    .alert(
      pendingSandboxfilePrompt?.title ?? "Create Sandboxfile?",
      isPresented: pendingSandboxfileAlertIsPresented
    ) {
      Button(pendingSandboxfilePrompt?.confirmTitle ?? "Create and Launch") {
        confirmSandboxedLaunch()
      }
      Button("Cancel", role: .cancel) {
        pendingLaunchProfile = nil
        pendingLaunchFocusPrompt = nil
        pendingSandboxfilePrompt = nil
      }
    } message: {
      if let prompt = pendingSandboxfilePrompt {
        Text(prompt.message)
      }
    }
  }

  private var canLaunch: Bool {
    guard !isLaunching else { return false }
    if useCustom {
      return !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let saved = selectedSavedAgent else { return false }
    return agentAvailability.status(for: saved) == .available
  }

  private var pendingSandboxfileAlertIsPresented: Binding<Bool> {
    Binding(
      get: { pendingSandboxfilePrompt != nil },
      set: { isPresented in
        if !isPresented {
          pendingLaunchProfile = nil
          pendingLaunchFocusPrompt = nil
          pendingSandboxfilePrompt = nil
        }
      }
    )
  }

  private func launch() {
    let profile: AgentProfile
    if useCustom {
      let cmd = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
      profile = AgentProfile(
        id: "custom-\(UUID().uuidString.prefix(8))",
        name: commandExecutableName(from: cmd),
        command: cmd,
        icon: "agent",
        isDetected: false,
        promptArgumentTemplate: ""
      )
    } else if let saved = selectedSavedAgent {
      let cmd = saved.fullCommand(yolo: yoloMode, sandboxed: sandboxEnabled)
      profile = AgentProfile(
        id: saved.id,
        name: yoloMode ? "\(saved.name) (YOLO)" : saved.name,
        command: cmd,
        icon: saved.icon,
        isDetected: true,
        promptArgumentTemplate: saved.promptArgumentTemplate
      )
    } else {
      return
    }

    let focus = focusPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedFocus = focus.isEmpty ? nil : focus
    isLaunching = true

    Task { @MainActor in
      do {
        if sandboxEnabled,
          let repoRoot = appState.repoRoot,
          let prompt = try await loadSandboxfilePromptIfNeeded(
            repoRoot: repoRoot,
            launchKind: .reviewer
          )
        {
          pendingLaunchProfile = profile
          pendingLaunchFocusPrompt = resolvedFocus
          pendingSandboxfilePrompt = prompt
          isLaunching = false
          return
        }

        performLaunch(profile: profile, focusPrompt: resolvedFocus)
      } catch {
        isLaunching = false
        appState.errorMessage = error.localizedDescription
      }
    }
  }

  private func confirmSandboxedLaunch() {
    guard let profile = pendingLaunchProfile, let prompt = pendingSandboxfilePrompt else { return }
    let focusPrompt = pendingLaunchFocusPrompt
    pendingLaunchProfile = nil
    pendingLaunchFocusPrompt = nil
    pendingSandboxfilePrompt = nil
    isLaunching = true

    Task { @MainActor in
      do {
        try await createRepoSandboxfile(request: prompt)
        performLaunch(profile: profile, focusPrompt: focusPrompt)
      } catch {
        isLaunching = false
        appState.errorMessage = error.localizedDescription
      }
    }
  }

  private func performLaunch(profile: AgentProfile, focusPrompt: String?) {
    appState.launchReviewerAgent(
      profile: profile,
      focusPrompt: focusPrompt,
      sandboxEnabled: sandboxEnabled
    )
    isLaunching = false
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
          let paths = try ArgonCLI.sandboxConfigPaths(repoRoot: repoRoot)
          return SandboxHelpData(repoRoot: repoRoot, paths: paths)
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

  @ViewBuilder
  private func savedAgentCard(for profile: SavedAgentProfile) -> some View {
    let status = agentAvailability.status(for: profile)
    AgentPickerCard(
      profile: profile,
      status: status,
      isSelected: !useCustom && selectedAgentId == profile.id
    ) {
      selectedAgentId = profile.id
      useCustom = false
      if profile.yoloFlag.isEmpty {
        yoloMode = false
      }
    }
  }

  private func yoloSubtitle(for flag: String) -> String {
    sandboxEnabled ? "Appends \(flag)." : "Dangerous without sandbox enabled."
  }

  private var yoloSubtitleColor: Color {
    sandboxEnabled ? .secondary : .red
  }
}

struct SandboxHelpData: Sendable {
  let repoRoot: String?
  let paths: ArgonCLI.SandboxConfigPaths
}

struct SandboxHelpPopover: View {
  let help: SandboxHelpData?
  let errorMessage: String?
  let isLoading: Bool

  private var platformLabel: String {
    "macOS"
  }

  private var configExample: String {
    """
    # This file describes the Argon Sandbox configuration
    # Full docs: https://github.com/fiam/argon/blob/main/SANDBOX.md

    ENV DEFAULT NONE # Start from a minimal process environment by default.
    FS DEFAULT NONE # Start from no filesystem access by default.
    EXEC DEFAULT ALLOW # Allow running any command by default.
    FS ALLOW READ . # Allow reading files inside this repository.
    FS ALLOW WRITE . # Allow edits inside this repository.
    USE os # Allow access to the operating system's shared filesystem without exposing personal directories.
    USE shell # Allow the current shell binary and shell history when they apply.
    USE agent # Load agent-specific config and state when they apply.
    IF TEST -f ./Sandboxfile.local # Check for an optional repo-local sandbox extension file.
        USE ./Sandboxfile.local
    END
    """
  }

  private var commandExamples: String {
    """
    argon --repo <repo> sandbox config paths
    argon sandbox init --repo-root <repo>
    argon sandbox builtin print shell
    argon sandbox explain --repo-root <repo> --launch shell --interactive
    """
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Sandbox configuration")
            .font(.headline)
          Text(
            "Sandboxed agents resolve policy by walking parent directories upward from the launch directory."
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
              label: "Init",
              value: help.paths.initPath ?? "Unavailable"
            )
            SandboxPathRow(
              label: "Loaded",
              value: help.paths.existingPaths.first ?? "None discovered"
            )
          } else if isLoading {
            ProgressView()
              .controlSize(.small)
          } else if let errorMessage {
            Text(errorMessage)
              .font(.caption)
              .foregroundStyle(.red)
          }

          Text(
            "Argon walks parent directories upward from the launch directory and loads at most one of `Sandboxfile`, `.Sandboxfile`, or `.Sanboxfile` from each directory."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Text(
            "If more than one sandbox file exists in the same directory, Argon errors instead of guessing."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Sandboxfile Syntax")
            .font(.subheadline)
            .fontWeight(.semibold)
          SandboxCodeBlock(text: configExample)
          Text(
            "Use `USE os`, `USE shell`, and `USE agent` to bring in built-in policy modules, then optionally include `./Sandboxfile.local` for local repo overrides."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Text(
            "Bare `EXEC ALLOW git` rules search `PATH` and allow each matching executable. Path-like values such as `./bin/tool` or `/usr/bin/git` refer to specific files."
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
          Text("Built-ins on \(platformLabel)")
            .font(.subheadline)
            .fontWeight(.semibold)
          Text(
            "`USE os`, `USE shell`, and `USE agent` are built-in modules that dispatch from the current launch context. `USE shell` and `USE agent` quietly do nothing when they do not apply."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Text(
            "`USE shell` is intentionally minimal: it covers the shell binary and shell history, but not personal shell startup files or prompt tools."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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
        Text(profile.name)
          .fontWeight(isSelected ? .medium : .regular)
          .lineLimit(1)
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
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
    .disabled(status == .unavailable)
    .opacity(status == .unavailable ? 0.55 : 1)
    .help(helpText)
  }

  private var helpText: String {
    switch status {
    case .checking:
      "Checking for command '\(profile.baseCommand)'"
    case .available:
      ""
    case .unavailable:
      "Command '\(profile.baseCommand)' not found"
    }
  }
}

struct CustomAgentPickerCard: View {
  let isSelected: Bool
  let accentColor: Color
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 6) {
        Image(systemName: "terminal")
          .font(.callout.weight(.medium))
          .foregroundStyle(isSelected ? accentColor : .secondary)
        Text("Custom Command")
          .fontWeight(isSelected ? .medium : .regular)
          .lineLimit(1)
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isSelected ? accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
      .foregroundStyle(isSelected ? accentColor : .primary)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isSelected ? accentColor.opacity(0.4) : Color(nsColor: .separatorColor), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .help("Run any command in a new agent tab.")
  }
}

struct ExternalAgentPickerCard: View {
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.up.right.square")
          .font(.callout.weight(.medium))
          .foregroundStyle(.secondary)
        Text("External Agent")
          .lineLimit(1)
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isHovering
          ? Color.accentColor.opacity(0.08)
          : Color(nsColor: .controlBackgroundColor)
      )
      .foregroundStyle(.primary)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isHovering ? Color.accentColor.opacity(0.22) : Color.clear,
            lineWidth: 1
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .help("Copy the review prompt and paste it into an external agent.")
    .onHover { hovering in
      isHovering = hovering
    }
  }
}
