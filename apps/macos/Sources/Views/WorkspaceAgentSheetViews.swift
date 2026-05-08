import AppKit
import SwiftUI

struct WorkspaceAgentTabSheet: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @Environment(SavedAgentProfiles.self) private var savedAgents
  @Environment(AgentAvailability.self) private var agentAvailability
  @Binding var isPresented: Bool
  let taskContext: WorkspaceAgentTaskContext
  let onLaunch: @MainActor (WorkspaceAgentLaunchOptions) async -> Bool
  let onExternalLaunch: @MainActor () async -> Bool
  let onDidLaunch: @MainActor () -> Void

  @State private var selectedAgentId: String?
  @State private var yoloMode = AgentLaunchSettings.isDefaultYoloModeEnabled()
  @State private var sandboxEnabled = AgentLaunchSettings.isDefaultSandboxEnabled()
  @State private var customCommand = ""
  @State private var useCustom = false
  @State private var isLaunching = false
  @State private var showSandboxHelp = false
  @State private var sandboxHelp: SandboxHelpData?
  @State private var sandboxHelpError: String?
  @State private var sandboxHelpLoading = false
  @State private var pendingSandboxfilePrompt: SandboxfilePromptRequest?
  @State private var pendingSandboxedLaunchOptions: WorkspaceAgentLaunchOptions?

  private var selectableSavedAgents: [SavedAgentProfile] {
    savedAgents.enabledProfiles
  }

  private var selectedSavedAgent: SavedAgentProfile? {
    guard let selectedAgentId else { return nil }
    return selectableSavedAgents.first { $0.id == selectedAgentId }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "sparkles.rectangle.stack")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text(sheetTitle)
            .font(.title2.weight(.semibold))
          Text(sheetSubtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("Agent")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
          if agentAvailability.hasPendingCommands {
            ProgressView()
              .controlSize(.small)
          }
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: AgentPickerLayout.gridMinimumWidth))], spacing: 8
        ) {
          ForEach(selectableSavedAgents) { profile in
            savedAgentCard(for: profile)
          }

          if taskContext.showsExternalOption {
            ExternalAgentPickerCard {
              launchExternal()
            }
            .disabled(isLaunching)
            .accessibilityIdentifier("workspace-review-external-button")
          }

          if taskContext.allowsCustomCommand {
            CustomAgentPickerCard(isSelected: useCustom, accentColor: .accentColor) {
              useCustom = true
              selectedAgentId = nil
              yoloMode = false
            }
          }
        }
      }

      if taskContext.allowsCustomCommand && useCustom {
        VStack(alignment: .leading, spacing: 8) {
          TextField("Command", text: $customCommand, prompt: Text("e.g. codex --yolo"))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .accessibilityIdentifier("workspace-agent-custom-command-field")
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

      if let selectedSavedAgent, !selectedSavedAgent.yoloFlag.isEmpty {
        Toggle(isOn: $yoloMode) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Yolo mode")
              .font(.callout)
            Text(yoloSubtitle(for: selectedSavedAgent.yoloFlag))
              .font(.caption)
              .foregroundStyle(yoloSubtitleColor)
          }
        }
        .toggleStyle(.checkbox)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isLaunching)

        Button("Launch") {
          launch()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canLaunch)
        .accessibilityIdentifier("workspace-agent-launch-button")
      }
    }
    .padding(24)
    .frame(width: 520)
    .onAppear {
      agentAvailability.refresh(for: selectableSavedAgents)
      syncSelectedAgent()
    }
    .onChange(of: savedAgents.profiles) { _, _ in
      agentAvailability.refresh(for: selectableSavedAgents)
      syncSelectedAgent()
    }
    .onChange(of: agentAvailability.revision) { _, _ in
      syncSelectedAgent()
    }
    .onChange(of: taskContext.allowsCustomCommand) { _, allowsCustomCommand in
      if !allowsCustomCommand {
        useCustom = false
      }
    }
    .alert(
      pendingSandboxfilePrompt?.title ?? "Create Sandboxfile?",
      isPresented: pendingSandboxfileAlertIsPresented
    ) {
      Button(pendingSandboxfilePrompt?.confirmTitle ?? "Create and Launch") {
        confirmSandboxedLaunch()
      }
      Button("Cancel", role: .cancel) {
        pendingSandboxedLaunchOptions = nil
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
    if taskContext.allowsCustomCommand && useCustom {
      return !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let selectedSavedAgent else { return false }
    return agentAvailability.status(for: selectedSavedAgent) == .available
  }

  private var pendingSandboxfileAlertIsPresented: Binding<Bool> {
    Binding(
      get: { pendingSandboxfilePrompt != nil },
      set: { isPresented in
        if !isPresented {
          pendingSandboxedLaunchOptions = nil
          pendingSandboxfilePrompt = nil
        }
      }
    )
  }

  private var sheetTitle: String {
    taskContext.sheetTitle
  }

  private var sheetSubtitle: String {
    taskContext.sheetSubtitle
  }

  private func launch() {
    guard let launchOptions else { return }

    isLaunching = true
    Task { @MainActor in
      do {
        if launchOptions.sandboxEnabled,
          let prompt = try await loadSandboxfilePromptIfNeeded(
            repoRoot: workspaceState.target.repoRoot,
            launchKind: .agent
          )
        {
          pendingSandboxedLaunchOptions = launchOptions
          pendingSandboxfilePrompt = prompt
          isLaunching = false
          return
        }

        await performLaunch(launchOptions)
      } catch {
        isLaunching = false
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  private func confirmSandboxedLaunch() {
    guard let launchOptions = pendingSandboxedLaunchOptions,
      let prompt = pendingSandboxfilePrompt
    else { return }
    pendingSandboxedLaunchOptions = nil
    pendingSandboxfilePrompt = nil
    isLaunching = true

    Task { @MainActor in
      do {
        try await createRepoSandboxfile(request: prompt)
        await performLaunch(launchOptions)
      } catch {
        isLaunching = false
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  private func performLaunch(_ launchOptions: WorkspaceAgentLaunchOptions) async {
    let didLaunch = await onLaunch(launchOptions)
    isLaunching = false
    guard didLaunch else { return }
    if case .savedProfile(let profile, _) = launchOptions.source {
      AgentSelectionSettings.recordLastSelectedAgentID(profile.id)
    }
    isPresented = false
    DispatchQueue.main.async {
      onDidLaunch()
    }
  }

  private func launchExternal() {
    guard !isLaunching else { return }

    isLaunching = true
    Task { @MainActor in
      let didLaunch = await onExternalLaunch()
      isLaunching = false
      guard didLaunch else { return }
      isPresented = false
    }
  }

  private var launchOptions: WorkspaceAgentLaunchOptions? {
    if taskContext.allowsCustomCommand && useCustom {
      let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else { return nil }
      return WorkspaceAgentLaunchOptions(
        source: .custom(
          displayName: commandExecutableName(from: command),
          command: command,
          icon: "agent"
        ),
        sandboxEnabled: sandboxEnabled
      )
    }

    guard let selectedSavedAgent else { return nil }
    return WorkspaceAgentLaunchOptions(
      source: .savedProfile(selectedSavedAgent, yoloMode: yoloMode),
      sandboxEnabled: sandboxEnabled
    )
  }

  private func syncSelectedAgent() {
    guard !useCustom else { return }
    if let selectedAgentId,
      let selected = selectableSavedAgents.first(where: { $0.id == selectedAgentId }),
      agentAvailability.status(for: selected) != .unavailable
    {
      return
    }

    if let preferredID = AgentSelectionSettings.preferredProfileID(
      in: selectableSavedAgents,
      isSelectable: { agentAvailability.status(for: $0) != .unavailable }
    ) {
      selectedAgentId = preferredID
      return
    }

    selectedAgentId =
      selectableSavedAgents.first(where: {
        agentAvailability.status(for: $0) == .available
      })?.id ?? selectableSavedAgents.first?.id
  }

  private func presentSandboxHelp() {
    showSandboxHelp = true
    guard !sandboxHelpLoading else { return }
    let repoRoot = workspaceState.target.repoRoot
    if sandboxHelp?.repoRoot == repoRoot, sandboxHelpError == nil {
      return
    }

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

  @ViewBuilder
  private func savedAgentCard(for profile: SavedAgentProfile) -> some View {
    let status = agentAvailability.status(for: profile)
    AgentPickerCard(
      profile: profile,
      status: status,
      isSelected: !useCustom && selectedAgentId == profile.id
    ) {
      selectSavedAgent(profile)
      if profile.yoloFlag.isEmpty {
        yoloMode = false
      }
    }
  }

  private func selectSavedAgent(_ profile: SavedAgentProfile) {
    selectedAgentId = profile.id
    useCustom = false
    AgentSelectionSettings.recordLastSelectedAgentID(profile.id)
  }

  private func yoloSubtitle(for flag: String) -> String {
    sandboxEnabled ? "Appends \(flag)." : "Dangerous without sandbox enabled."
  }

  private var yoloSubtitleColor: Color {
    sandboxEnabled ? .secondary : .red
  }
}

enum WorkspaceAgentTaskContext {
  case general
  case reviewHandoff
  case finalize(WorktreeFinalizeAction)

  var allowsCustomCommand: Bool {
    switch self {
    case .general:
      false
    case .reviewHandoff, .finalize(_):
      true
    }
  }

  var showsExternalOption: Bool {
    if case .reviewHandoff = self {
      return true
    }
    return false
  }

  var sheetTitle: String {
    switch self {
    case .general:
      "New Agent Tab"
    case .reviewHandoff:
      "Launch Review Agent"
    case .finalize(let action):
      action.launchSheetTitle
    }
  }

  var sheetSubtitle: String {
    switch self {
    case .general:
      "Launch a saved agent in the selected worktree."
    case .reviewHandoff:
      "Launch a coder tab here, or copy the review prompt for your own external agent."
    case .finalize(let action):
      action.launchSheetSubtitle
    }
  }
}

struct WorkspaceNewWorktreeSheet: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @Binding var isPresented: Bool

  @FocusState private var focusedField: FocusedField?
  @State private var branchName = ""
  @State private var path = ""
  @State private var startPoint = ""
  @State private var lastSuggestedPath = ""
  @State private var hasCustomizedPath = false

  private enum FocusedField: Hashable {
    case branchName
    case startPoint
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "square.stack.badge.plus")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("New Worktree")
            .font(.title2.weight(.semibold))
          Text("Create a branch-backed worktree and focus it in this workspace.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Branch name")
            .font(.callout.weight(.medium))
          TextField("feature/refocus-workspace", text: $branchName)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .focused($focusedField, equals: .branchName)
            .disabled(workspaceState.isCreatingWorktree)
            .accessibilityIdentifier("workspace-new-worktree-branch-name-field")
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Path")
            .font(.callout.weight(.medium))

          DirectoryPathControl(path: path) {
            chooseWorktreeDirectory()
          }
          .frame(height: 22)
          .help(path)
          .disabled(workspaceState.isCreatingWorktree)

          HStack(spacing: 8) {
            Button("Use Suggested") {
              path = lastSuggestedPath
              hasCustomizedPath = false
            }
            .controlSize(.small)
            .disabled(path == lastSuggestedPath || workspaceState.isCreatingWorktree)
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Start from")
            .font(.callout.weight(.medium))
          TextField("HEAD", text: $startPoint)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .focused($focusedField, equals: .startPoint)
            .disabled(workspaceState.isCreatingWorktree)
            .accessibilityIdentifier("workspace-new-worktree-start-point-field")

          Text("Defaults to the inferred base branch for the repository.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack {
        Spacer()

        Button("Cancel") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)

        Button {
          createWorktree()
        } label: {
          ZStack {
            Text("Create Worktree")
              .frame(minWidth: 120)
              .opacity(workspaceState.isCreatingWorktree ? 0 : 1)

            if workspaceState.isCreatingWorktree {
              ProgressView()
                .controlSize(.small)
            }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canCreate)
        .accessibilityIdentifier("workspace-new-worktree-create-button")
      }
    }
    .padding(24)
    .frame(width: 520)
    .onAppear {
      let suggestedPath = workspaceState.suggestedWorktreePath(branchName: branchName)
      path = suggestedPath
      lastSuggestedPath = suggestedPath
      startPoint = workspaceState.defaultNewWorktreeStartPoint()
    }
    .onChange(of: branchName) { previousValue, newValue in
      let suggestion = workspaceState.suggestedWorktreePath(branchName: newValue)
      if !hasCustomizedPath || path == lastSuggestedPath || previousValue.isEmpty {
        path = suggestion
      }
      lastSuggestedPath = suggestion
      hasCustomizedPath = path != suggestion
    }
    .onChange(of: path) { _, newValue in
      hasCustomizedPath = newValue != lastSuggestedPath
    }
    .onChange(of: workspaceState.isCreatingWorktree) { _, isCreating in
      if isCreating {
        clearInputFocus()
      }
    }
  }

  private var canCreate: Bool {
    !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !workspaceState.isCreatingWorktree
  }

  @MainActor
  private func createWorktree() {
    guard canCreate else { return }
    clearInputFocus()

    Task {
      do {
        try await workspaceState.createWorktree(
          branchName: branchName,
          path: path,
          startPoint: startPoint
        )
        isPresented = false
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  @MainActor
  private func chooseWorktreeDirectory() {
    guard !workspaceState.isCreatingWorktree else { return }

    let panel = NSOpenPanel()
    panel.title = "Choose Worktree Destination"
    panel.message = "Select or create the destination directory for the new worktree."
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()

    guard panel.runModal() == .OK, let url = panel.url else { return }
    path = url.standardizedFileURL.path
    hasCustomizedPath = path != lastSuggestedPath
  }

  @MainActor
  private func clearInputFocus() {
    focusedField = nil
    _ = NSApp.keyWindow?.makeFirstResponder(nil)
  }
}
