import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Displays an agent icon from the asset catalog, falling back to an SF Symbol.
struct AgentIconView: View {
  let icon: String
  var size: CGFloat = 16

  var body: some View {
    if let customImage {
      customImage
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    } else {
      Image(systemName: sfSymbolFallback)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    }
  }

  private var sfSymbolFallback: String {
    switch icon {
    case "claude":
      return "brain"
    case "codex":
      return "rectangle.and.text.magnifyingglass"
    case "gemini":
      return "sparkles"
    case "agent", "terminal":
      return "sparkles.rectangle.stack"
    default:
      return "sparkles.rectangle.stack"
    }
  }

  private var customImage: Image? {
    switch icon {
    case "claude":
      return Image(.claude)
    case "codex":
      return Image(.codex)
    case "gemini":
      return Image(.gemini)
    default:
      return nil
    }
  }
}

struct SettingsView: View {
  fileprivate static let tabHorizontalPadding: CGFloat = 12
  fileprivate static let tabTopPadding: CGFloat = 10
  fileprivate static let tabBottomPadding: CGFloat = 10
  fileprivate static let formLikeVStackHorizontalPadding: CGFloat = 40
  fileprivate static let formLikeVStackTopPadding: CGFloat = 22

  @Environment(CommandContext.self) private var commandContext
  @Environment(\.colorScheme) private var colorScheme
  @Environment(SavedAgentProfiles.self) private var savedAgents
  @Environment(AgentAvailability.self) private var agentAvailability
  @Environment(WorkspaceTerminalAttentionNotifier.self) private var terminalAttentionNotifier
  @EnvironmentObject private var appUpdateController: AppUpdateController
  @AppStorage("defaultDiffViewMode") private var defaultDiffViewMode = "unified"
  @AppStorage("diffFontSize") private var diffFontSize = 13.0
  @AppStorage(CommentFontSettings.storageKey)
  private var commentFontSize = CommentFontSettings.defaultSize
  @AppStorage("terminalFontSize") private var terminalFontSize = 12.0
  @AppStorage(GhosttyConfigurationSettings.storageKey) private var ghosttyConfigurationOverride = ""
  @AppStorage(WorktreeRootSettings.storageKey)
  private var worktreeRootPath = WorktreeRootSettings.defaultRootPath()
  @AppStorage(WorkspaceFinishedTerminalBehavior.storageKey)
  private var finishedTerminalBehavior = WorkspaceFinishedTerminalBehavior.autoClose.rawValue
  @AppStorage(AgentSleepPreventionSettings.enabledStorageKey)
  private var preventSleepWhileAgentsRun = AgentSleepPreventionSettings.defaultEnabled
  @AppStorage(AgentNotificationSettings.enabledStorageKey)
  private var agentNotificationsEnabled = AgentNotificationSettings.defaultEnabled
  @AppStorage(AgentTerminalPersistenceExperimentSettings.enabledStorageKey)
  private var experimentalPersistentAgentTerminals =
    AgentTerminalPersistenceExperimentSettings.defaultEnabled
  @AppStorage(AgentSelectionSettings.rememberLastSelectionStorageKey)
  private var rememberLastAgentSelection = AgentSelectionSettings.defaultRememberLastSelection
  @AppStorage(WorktreeMergeStrategySettings.defaultStrategyStorageKey)
  private var defaultWorktreeMergeStrategy = WorktreeMergeStrategy.mergeCommit.rawValue
  @State private var selectedAgentId: String?
  @State private var draggingAgentId: String?
  @State private var dropInsertion: AgentDropInsertion?
  @State private var editingNewAgent = false
  @State private var ghosttyConfigurationDraft = ""
  @State private var appliedGhosttyConfigurationText = ""
  @State private var didLoadGhosttyConfigurationDraft = false
  @State private var terminalPreviewAppearance: TerminalPreviewAppearance = .dark
  @State private var didInitializeTerminalPreviewAppearance = false
  @State private var sandboxSnapshot: SandboxfileSettingsSnapshot?
  @State private var sandboxErrorMessage: String?
  @State private var sandboxLoading = false
  @State private var selectedSandboxLayer: SandboxfileSettingsLayer = .project
  @State private var sandboxDraft = ""
  @State private var appliedSandboxText = ""
  @State private var sandboxSaving = false
  @State private var cliInstallStatus = ArgonCLIInstallLink.status()
  @State private var cliInstallBusy = false
  @State private var cliInstallErrorMessage: String?
  @State private var notificationSettingsAlertMessage: String?

  var body: some View {
    TabView {
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }
      workspaceTab
        .tabItem { Label("Workspace", systemImage: "folder") }
      reviewTab
        .tabItem { Label("Review", systemImage: "text.page") }
      agentsTab
        .tabItem { Label("Agents", systemImage: "person.2") }
      sandboxTab
        .tabItem { Label("Sandbox", systemImage: "shield") }
      terminalTab
        .tabItem { Label("Terminal", systemImage: "terminal") }
    }
    .frame(width: 550, height: 400)
    .alert(
      "Agent Notifications",
      isPresented: notificationSettingsAlertIsPresented
    ) {
      Button("Open System Settings") {
        terminalAttentionNotifier.openSystemNotificationSettings()
      }
      Button("OK", role: .cancel) {}
    } message: {
      Text(notificationSettingsAlertMessage ?? "")
    }
  }

  private var generalTab: some View {
    Form {
      Section("Updates") {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 8) {
            Text("Argon \(appUpdateController.currentVersion)")

            Spacer(minLength: 0)

            Button("Check for Updates…") {
              appUpdateController.checkForUpdates()
            }
            .disabled(!appUpdateController.canCheckForUpdates)
          }

          Text(appUpdateController.statusText)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Section("Command Line Tool") {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 8) {
            Label(cliInstallStatus.title, systemImage: cliInstallStatus.symbolName)
              .foregroundStyle(cliInstallStatus.isHealthy ? .green : .orange)

            Spacer(minLength: 0)

            if cliInstallBusy {
              ProgressView()
                .controlSize(.small)
            }
          }

          Text(cliInstallStatus.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if let cliInstallErrorMessage {
            Text(cliInstallErrorMessage)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }

          if cliInstallStatus.canRepair {
            HStack {
              Spacer(minLength: 0)
              Button(cliInstallStatus.repairButtonTitle) {
                Task {
                  await repairCLIInstallLink()
                }
              }
              .disabled(cliInstallBusy)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .settingsTabInsets()
    .task {
      refreshCLIInstallStatus()
    }
  }

  private var workspaceTab: some View {
    Form {
      Section("Worktrees") {
        HStack(spacing: 8) {
          DirectoryPathControl(
            path: worktreeRootPath,
            placeholder: "Choose worktree root"
          ) {
            chooseWorktreeRootDirectory()
          }
          .frame(minWidth: 220, idealWidth: 280, maxWidth: .infinity)
          .frame(height: 22)
          .help(worktreeRootPath)

          Button("Reset to Default") {
            worktreeRootPath = WorktreeRootSettings.defaultRootPath()
          }
          .controlSize(.small)
          .disabled(worktreeRootPath == WorktreeRootSettings.defaultRootPath())
        }
      }

      Section("Merge Back") {
        Picker("Default merge style", selection: $defaultWorktreeMergeStrategy) {
          ForEach(WorktreeMergeStrategy.allCases) { strategy in
            Text(strategy.menuTitle)
              .tag(strategy.rawValue)
          }
        }
        .pickerStyle(.menu)
      }

      Section("Agents") {
        Toggle("Prevent sleep while agents are running", isOn: $preventSleepWhileAgentsRun)
          .help("Keep this Mac awake while at least one agent tab is running.")

        VStack(alignment: .leading, spacing: 6) {
          Toggle("Agent notifications", isOn: agentNotificationsEnabledBinding)
            .help(
              "Notify when an agent needs your attention or finishes running."
            )
            .disabled(terminalAttentionNotifier.authorizationStatus == .denied)

          Text(agentNotificationStatusText)
            .font(.caption)
            .foregroundStyle(agentNotificationStatusColor)
            .fixedSize(horizontal: false, vertical: true)

          if terminalAttentionNotifier.authorizationStatus == .denied {
            Button("Open System Settings…") {
              terminalAttentionNotifier.openSystemNotificationSettings()
            }
            .controlSize(.small)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          Toggle(
            "Persistent agent terminals",
            isOn: $experimentalPersistentAgentTerminals
          )
          .help("Keep thinking agents running through a terminal session wrapper.")
          .disabled(!TerminalSessionBackends.isAvailable())

          Text(
            "Experimental. Keeps thinking agents running after Argon quits, then reconnects to them on the next launch."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      Section("Terminals") {
        Toggle("Close finished terminals automatically", isOn: autoCloseFinishedTerminalsBinding)
          .help(selectedFinishedTerminalBehavior.helpText)
      }
    }
    .formStyle(.grouped)
    .settingsTabInsets()
    .task {
      await terminalAttentionNotifier.refreshAuthorizationStatus()
    }
  }

  private var reviewTab: some View {
    Form {
      Section("Diff") {
        Toggle("Side-by-side diffs", isOn: sideBySideDiffsBinding)
          .help("Show old content and new content in separate columns by default.")

        HStack {
          Text("Font size: \(Int(diffFontSize))pt")
          Slider(value: $diffFontSize, in: 10...24, step: 1)
        }
        Text("The quick brown fox jumps over the lazy dog")
          .font(.system(size: diffFontSize, design: .monospaced))
          .foregroundStyle(.secondary)
      }

      Section("Comments") {
        HStack {
          Text("Font size: \(Int(effectiveCommentFontSize))pt")
          Slider(value: $commentFontSize, in: CommentFontSettings.range, step: 1)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Reviewer")
            .font(.system(size: max(effectiveCommentFontSize - 2, 10), weight: .semibold))
            .foregroundStyle(.secondary)
          Text("This comment text uses your configured comment size.")
            .font(.system(size: effectiveCommentFontSize))
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .settingsTabInsets()
  }

  // MARK: - Agents Tab

  private var agentsTab: some View {
    VStack(spacing: 0) {
      HStack {
        Toggle("Remember last selected agent", isOn: $rememberLastAgentSelection)
          .toggleStyle(.checkbox)
          .help("Preselect the most recently selected saved agent when opening agent pickers.")
          .accessibilityIdentifier("agent-settings-remember-last-selection-toggle")
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)

      List(selection: $selectedAgentId) {
        ForEach(savedAgents.profiles) { profile in
          AgentProfileRow(
            profile: profile,
            availability: agentAvailability.details(for: profile),
            dropPlacement: dropInsertion?.profileID == profile.id ? dropInsertion?.placement : nil,
            onSetEnabled: { isEnabled in
              savedAgents.setEnabled(isEnabled, for: profile.id)
            },
            onDisableOrRemove: {
              savedAgents.remove(id: profile.id)
              if !savedAgents.profiles.contains(where: { $0.id == profile.id }) {
                selectedAgentId = nil
              }
            },
            onDrag: {
              draggingAgentId = profile.id
              return NSItemProvider(object: profile.id as NSString)
            },
            onUpdate: { updated in
              savedAgents.update(updated)
            }
          )
          .tag(profile.id)
          .opacity(draggingAgentId == profile.id ? 0.55 : 1)
          .simultaneousGesture(
            TapGesture().onEnded {
              selectedAgentId = profile.id
            }
          )
          .onDrop(
            of: [.text],
            delegate: AgentProfileDropDelegate(
              destinationProfileID: profile.id,
              profiles: savedAgents.profiles,
              draggingAgentId: $draggingAgentId,
              dropInsertion: $dropInsertion
            ) { source, destination in
              savedAgents.move(from: source, to: destination)
            }
          )
        }
        .onDelete { offsets in
          savedAgents.remove(at: offsets)
        }
        .onMove { source, destination in
          savedAgents.move(from: source, to: destination)
        }
      }
      .environment(\.defaultMinListRowHeight, 48)
      .listStyle(.bordered(alternatesRowBackgrounds: true))

      // HIG-style segmented action bar
      HStack(spacing: 0) {
        HStack(spacing: 0) {
          Button {
            editingNewAgent = true
          } label: {
            Image(systemName: "plus")
              .frame(width: 28, height: 22)
              .contentShape(Rectangle())
          }

          Divider()
            .frame(height: 16)

          Button {
            disableOrRemoveSelectedAgent()
          } label: {
            Image(systemName: "minus")
              .frame(width: 28, height: 22)
              .contentShape(Rectangle())
          }
          .disabled(!canDisableOrRemoveSelectedAgent)
          .help(disableOrRemoveSelectedAgentHelpText)
        }
        .buttonStyle(.borderless)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )

        Spacer()

        Button("Reset to Defaults") {
          savedAgents.resetToDefaults()
          selectedAgentId = nil
        }
        .controlSize(.small)
      }
      .padding(8)
    }
    .formLikeVStackInsets()
    .sheet(isPresented: $editingNewAgent) {
      AgentEditorSheet(
        profile: SavedAgentProfile(
          id: "custom-\(UUID().uuidString.prefix(8))",
          name: "",
          command: "",
          icon: "agent",
          yoloFlag: "",
          promptArgumentTemplate: "",
          resumeArgumentTemplate: ""
        )
      ) { newProfile in
        savedAgents.add(newProfile)
      }
    }
  }

  private var selectedAgentProfile: SavedAgentProfile? {
    guard let selectedAgentId else { return nil }
    return savedAgents.profiles.first { $0.id == selectedAgentId }
  }

  private var canDisableOrRemoveSelectedAgent: Bool {
    guard let selectedAgentProfile else { return false }
    return !selectedAgentProfile.isBuiltIn || selectedAgentProfile.isEnabled
  }

  private var disableOrRemoveSelectedAgentHelpText: String {
    guard let selectedAgentProfile else { return "Select an agent first." }
    if selectedAgentProfile.isBuiltIn {
      return selectedAgentProfile.isEnabled
        ? "Disable this built-in agent in launch pickers."
        : "This built-in agent is already disabled."
    }
    return "Delete this custom agent."
  }

  private func disableOrRemoveSelectedAgent() {
    guard let selectedAgentProfile else { return }
    savedAgents.remove(id: selectedAgentProfile.id)
    if !savedAgents.profiles.contains(where: { $0.id == selectedAgentProfile.id }) {
      selectedAgentId = nil
    }
  }

  private var sandboxTab: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 10) {
        Text("Sandbox")
          .font(.title3)
          .fontWeight(.semibold)
        Link("Docs", destination: SandboxfileHelpContent.docsURL)
          .font(.subheadline)
          .pointingHandCursorOnHover()
        Spacer(minLength: 0)

        SandboxLayerPillSelector(selection: $selectedSandboxLayer)

        Button {
          insertSandboxScaffold()
        } label: {
          Image(systemName: "plus")
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canInsertSandboxScaffold)
        .help(insertScaffoldHelpText)
      }

      if sandboxLoading {
        ProgressView("Loading Sandboxfiles…")
          .controlSize(.small)
      } else if let sandboxErrorMessage {
        Text(sandboxErrorMessage)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        HighlightedCodeTextView(
          text: $sandboxDraft,
          path: sandboxHighlightPath,
          fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
          theme: highlightTheme,
          accessibilityIdentifier: "sandbox-editor"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )

        HStack(alignment: .center, spacing: 10) {
          Text(sandboxFooterText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          Spacer(minLength: 0)

          Button("Revert") {
            revertSandboxDraft()
          }
          .disabled(!hasUnsavedSandboxChanges || sandboxSaving)

          Button("Save") {
            Task {
              await saveSelectedSandboxfile()
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canSaveSandboxDraft || sandboxSaving)
        }
      }
    }
    .formLikeVStackInsets()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task(id: sandboxSettingsRootPath) {
      await reloadSandboxSnapshot()
    }
    .onChange(of: selectedSandboxLayer) { _, _ in
      syncSandboxEditorState()
    }
  }

  // MARK: - Terminal Tab

  private var terminalTab: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text("Preview")
          .font(.headline)
          .fontWeight(.semibold)
        Spacer(minLength: 0)
        Toggle(isOn: terminalPreviewDarkModeBinding) {
          Text("Dark")
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
      }

      GroupBox {
        TerminalPreview(
          terminalFontSize: effectiveTerminalPreviewFontSize,
          appearance: terminalPreviewAppearance
        )
        .frame(maxWidth: .infinity)
        .frame(height: 80)
      }

      HStack(spacing: 10) {
        Text("Ghostty Config")
          .font(.headline)
          .fontWeight(.semibold)
        Link("Docs", destination: GhosttyConfigurationSettings.docsURL)
          .font(.subheadline)
          .pointingHandCursorOnHover()
        Spacer(minLength: 0)
        Text("Argon uses Ghostty to render terminals.")
          .foregroundStyle(.secondary)
          .font(.subheadline)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          if hasUnsavedGhosttyConfigurationChanges {
            HStack {
              Spacer()
              Text("Unsaved changes")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }

          ZStack(alignment: .topLeading) {
            // SwiftUI's TextEditor cannot render the attributed syntax highlighting
            // used for Ghostty config tokens, so this field uses an NSTextView wrapper.
            HighlightedCodeTextView(
              text: $ghosttyConfigurationDraft,
              path: GhosttyConfigurationSettings.highlightPath,
              fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
              theme: highlightTheme
            )
            .frame(height: 170)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            if ghosttyConfigurationDraft.isEmpty {
              Text("# Optional Ghostty overrides")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
                .allowsHitTesting(false)
            }
          }

          HStack(spacing: 10) {
            Spacer()
            Button("Revert") {
              ghosttyConfigurationDraft = appliedGhosttyConfigurationText
            }
            .disabled(!hasUnsavedGhosttyConfigurationChanges)

            Button("Save & Apply") {
              saveAndApplyGhosttyConfiguration()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnsavedGhosttyConfigurationChanges)
          }
        }
      }
    }
    .formLikeVStackInsets()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      loadGhosttyConfigurationDraftIfNeeded()
      initializeTerminalPreviewAppearanceIfNeeded()
    }
  }

  private var selectedFinishedTerminalBehavior: WorkspaceFinishedTerminalBehavior {
    WorkspaceFinishedTerminalBehavior(rawValue: finishedTerminalBehavior) ?? .autoClose
  }

  private var notificationSettingsAlertIsPresented: Binding<Bool> {
    Binding(
      get: { notificationSettingsAlertMessage != nil },
      set: { isPresented in
        if !isPresented {
          notificationSettingsAlertMessage = nil
        }
      }
    )
  }

  private var agentNotificationsEnabledBinding: Binding<Bool> {
    Binding(
      get: { agentNotificationsEnabled },
      set: { isEnabled in
        Task { @MainActor in
          await updateAgentNotificationsEnabled(isEnabled)
        }
      }
    )
  }

  private var sideBySideDiffsBinding: Binding<Bool> {
    Binding(
      get: { defaultDiffViewMode == "sideBySide" },
      set: { isEnabled in
        defaultDiffViewMode = isEnabled ? "sideBySide" : "unified"
      }
    )
  }

  private var agentNotificationStatusText: String {
    switch terminalAttentionNotifier.authorizationStatus {
    case .authorized:
      return agentNotificationsEnabled
        ? "Argon will notify you when agents need attention or finish running."
        : "Agent notifications are off."
    case .denied:
      return
        "Without notifications, Argon cannot tell you when an agent is done or needs your attention. Enable Argon in System Settings > Notifications."
    case .notDetermined:
      return agentNotificationsEnabled
        ? "Argon will ask for notification permission the next time you launch an agent."
        : "Agent notifications are off."
    case .unknown:
      return "Notification permission status is unavailable."
    }
  }

  private var agentNotificationStatusColor: Color {
    terminalAttentionNotifier.authorizationStatus == .denied ? .orange : .secondary
  }

  private func refreshCLIInstallStatus() {
    cliInstallStatus = ArgonCLIInstallLink.status()
  }

  @MainActor
  private func updateAgentNotificationsEnabled(_ isEnabled: Bool) async {
    let result = await terminalAttentionNotifier.setAgentNotificationsEnabledFromSettings(
      isEnabled)
    agentNotificationsEnabled = AgentNotificationSettings.isEnabled()

    if result == .disabledBySystemPermission {
      notificationSettingsAlertMessage =
        "Without notifications, Argon cannot tell you when an agent is done or needs your attention. Open System Settings > Notifications and allow notifications for Argon."
    }
  }

  @MainActor
  private func repairCLIInstallLink() async {
    cliInstallBusy = true
    cliInstallErrorMessage = nil
    defer { cliInstallBusy = false }

    do {
      cliInstallStatus = try ArgonCLIInstallLink.repair()
    } catch {
      cliInstallErrorMessage = error.localizedDescription
      cliInstallStatus = ArgonCLIInstallLink.status()
    }
  }

  private var autoCloseFinishedTerminalsBinding: Binding<Bool> {
    Binding(
      get: { selectedFinishedTerminalBehavior == .autoClose },
      set: { isEnabled in
        finishedTerminalBehavior =
          isEnabled
          ? WorkspaceFinishedTerminalBehavior.autoClose.rawValue
          : WorkspaceFinishedTerminalBehavior.keepOpen.rawValue
      }
    )
  }

  private func chooseWorktreeRootDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Choose Worktree Root"
    panel.message = "Select the directory Argon should use for new worktrees."
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: worktreeRootPath, isDirectory: true)

    guard panel.runModal() == .OK, let url = panel.url else { return }
    worktreeRootPath = url.standardizedFileURL.path
  }

  private var effectiveCommentFontSize: Double {
    CommentFontSettings.clamped(commentFontSize)
  }

  private var effectiveTerminalPreviewFontSize: Double {
    if let draftValue = GhosttyConfigurationSettings.fontSize(from: ghosttyConfigurationDraft) {
      return draftValue
    }
    if let appliedValue = GhosttyConfigurationSettings.fontSize(
      from: appliedGhosttyConfigurationText)
    {
      return appliedValue
    }
    return terminalFontSize
  }

  private var hasUnsavedGhosttyConfigurationChanges: Bool {
    ghosttyConfigurationDraft != appliedGhosttyConfigurationText
  }

  private var highlightTheme: String {
    colorScheme == .dark ? "base16-ocean.dark" : "base16-ocean.light"
  }

  private var sandboxSettingsRootPath: String? {
    commandContext.sandboxSettingsRoot
  }

  private var selectedSandboxSource: SandboxfileSettingsSource? {
    sandboxSnapshot?.editableSource(for: selectedSandboxLayer)
  }

  private var sandboxHighlightPath: String {
    "sandbox.sh"
  }

  private var selectedSandboxSavePath: String? {
    switch selectedSandboxLayer {
    case .project:
      selectedSandboxSource?.path ?? projectSandboxfileCreationPath
    case .personal:
      selectedSandboxSource?.path ?? personalSandboxfilePath
    }
  }

  private var canInsertSandboxScaffold: Bool {
    selectedSandboxSource == nil && selectedSandboxSavePath != nil
  }

  private var insertScaffoldHelpText: String {
    switch selectedSandboxLayer {
    case .project:
      "Insert the default project Sandboxfile scaffold"
    case .personal:
      "Insert the default personal .Sandboxfile scaffold"
    }
  }

  private var hasUnsavedSandboxChanges: Bool {
    sandboxDraft != appliedSandboxText
  }

  private var canSaveSandboxDraft: Bool {
    selectedSandboxSavePath != nil && hasUnsavedSandboxChanges
  }

  private var sandboxFooterText: String {
    var messages = [
      "Changes saved here only affect future sandbox launches. Running sandboxes keep their current policy."
    ]

    if selectedSandboxLayer == .project,
      let snapshot = sandboxSnapshot
    {
      let inheritedCount = snapshot.inheritedSourceCount(for: .project)
      if inheritedCount > 0 {
        let noun = inheritedCount == 1 ? "Sandboxfile is" : "Sandboxfiles are"
        messages.append("\(inheritedCount) parent project \(noun) also loaded after this file.")
      }
    }

    return messages.joined(separator: " ")
  }

  private var terminalPreviewDarkModeBinding: Binding<Bool> {
    Binding(
      get: { terminalPreviewAppearance == .dark },
      set: { isDark in
        terminalPreviewAppearance = isDark ? .dark : .light
      }
    )
  }

  private func loadGhosttyConfigurationDraftIfNeeded() {
    guard !didLoadGhosttyConfigurationDraft else { return }
    didLoadGhosttyConfigurationDraft = true

    let overrideValue = ghosttyConfigurationOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    if !overrideValue.isEmpty {
      ghosttyConfigurationDraft = ghosttyConfigurationOverride
      appliedGhosttyConfigurationText = ghosttyConfigurationOverride
      return
    }

    let resolved = GhosttyConfigurationSettings.resolvedConfigText() ?? ""
    ghosttyConfigurationDraft = resolved
    appliedGhosttyConfigurationText = resolved
  }

  private func saveAndApplyGhosttyConfiguration() {
    let value =
      ghosttyConfigurationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? ""
      : ghosttyConfigurationDraft
    ghosttyConfigurationDraft = value
    ghosttyConfigurationOverride = value
    appliedGhosttyConfigurationText = value
  }

  private func initializeTerminalPreviewAppearanceIfNeeded() {
    guard !didInitializeTerminalPreviewAppearance else { return }
    didInitializeTerminalPreviewAppearance = true
    terminalPreviewAppearance = colorScheme == .dark ? .dark : .light
  }

  private var personalSandboxfilePath: String {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Sandboxfile").path
  }

  private var projectSandboxfileCreationPath: String? {
    sandboxSnapshot?.initPath
      ?? sandboxSettingsRootPath.map {
        URL(fileURLWithPath: $0).appendingPathComponent("Sandboxfile").path
      }
  }

  private func syncSandboxEditorState() {
    let contents = selectedSandboxSource?.contents ?? ""
    sandboxDraft = contents
    appliedSandboxText = contents
  }

  @MainActor
  private func reloadSandboxSnapshot() async {
    guard let rootPath = sandboxSettingsRootPath else {
      sandboxLoading = false
      sandboxErrorMessage = nil
      sandboxSnapshot = nil
      syncSandboxEditorState()
      return
    }

    sandboxLoading = true
    sandboxErrorMessage = nil

    let result = await Task.detached(priority: .userInitiated) {
      Result {
        try SandboxfileSettingsSnapshotLoader.load(rootPath: rootPath)
      }
    }.value

    guard rootPath == sandboxSettingsRootPath else { return }

    sandboxLoading = false
    switch result {
    case .success(let snapshot):
      sandboxSnapshot = snapshot
      sandboxErrorMessage = nil
      syncSandboxEditorState()
    case .failure(let error):
      sandboxSnapshot = nil
      sandboxErrorMessage = error.localizedDescription
      syncSandboxEditorState()
    }
  }

  private func insertSandboxScaffold() {
    let kind: SandboxfileScaffoldKind =
      selectedSandboxLayer == .project ? .project : .personal
    sandboxDraft = renderSandboxfile(kind: kind)
  }

  private func revertSandboxDraft() {
    sandboxDraft = appliedSandboxText
  }

  @MainActor
  private func saveSelectedSandboxfile() async {
    guard let path = selectedSandboxSavePath else { return }
    sandboxSaving = true
    defer { sandboxSaving = false }

    do {
      try await saveSandboxfile(atPath: path, contents: sandboxDraft)
      await reloadSandboxSnapshot()
    } catch {
      sandboxErrorMessage = error.localizedDescription
    }
  }
}

private struct SandboxLayerPillSelector: View {
  @Binding var selection: SandboxfileSettingsLayer

  var body: some View {
    HStack(spacing: 4) {
      ForEach(SandboxfileSettingsLayer.allCases) { layer in
        Button {
          selection = layer
        } label: {
          Text(layer.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selection == layer ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
              Capsule()
                .fill(selection == layer ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(Capsule())
    .overlay(
      Capsule()
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }
}

private struct PointingHandCursorOnHoverModifier: ViewModifier {
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .onHover { hovering in
        if hovering {
          guard !isHovering else { return }
          NSCursor.pointingHand.push()
          isHovering = true
        } else if isHovering {
          NSCursor.pop()
          isHovering = false
        }
      }
      .onDisappear {
        if isHovering {
          NSCursor.pop()
          isHovering = false
        }
      }
  }
}

extension View {
  fileprivate func settingsTabInsets() -> some View {
    self
      .padding(.horizontal, SettingsView.tabHorizontalPadding)
      .padding(.top, SettingsView.tabTopPadding)
      .padding(.bottom, SettingsView.tabBottomPadding)
  }

  fileprivate func formLikeVStackInsets() -> some View {
    self
      .padding(.horizontal, SettingsView.formLikeVStackHorizontalPadding)
      .padding(.top, SettingsView.formLikeVStackTopPadding)
      .padding(.bottom, SettingsView.tabBottomPadding)
  }

  fileprivate func pointingHandCursorOnHover() -> some View {
    modifier(PointingHandCursorOnHoverModifier())
  }
}

private enum TerminalPreviewAppearance: String, CaseIterable, Identifiable {
  case dark
  case light

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dark:
      "Dark"
    case .light:
      "Light"
    }
  }
}

private struct TerminalPreview: View {
  let terminalFontSize: Double
  let appearance: TerminalPreviewAppearance

  private var backgroundColor: Color {
    switch appearance {
    case .dark:
      Color(red: 0.11, green: 0.12, blue: 0.14)
    case .light:
      Color(red: 0.97, green: 0.97, blue: 0.98)
    }
  }

  private var borderColor: Color {
    switch appearance {
    case .dark:
      Color.white.opacity(0.14)
    case .light:
      Color.black.opacity(0.12)
    }
  }

  private var primaryColor: Color {
    switch appearance {
    case .dark:
      Color(red: 0.90, green: 0.92, blue: 0.95)
    case .light:
      Color(red: 0.17, green: 0.20, blue: 0.26)
    }
  }

  private var secondaryColor: Color {
    switch appearance {
    case .dark:
      Color(red: 0.64, green: 0.69, blue: 0.76)
    case .light:
      Color(red: 0.42, green: 0.47, blue: 0.55)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Circle().fill(Color.red.opacity(0.9)).frame(width: 9, height: 9)
        Circle().fill(Color.yellow.opacity(0.9)).frame(width: 9, height: 9)
        Circle().fill(Color.green.opacity(0.9)).frame(width: 9, height: 9)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("$ argon review --mode uncommitted")
          .foregroundStyle(primaryColor)
        Text("Awaiting reviewer feedback...")
          .foregroundStyle(secondaryColor)
        Text("[ok] 3 comments addressed")
          .foregroundStyle(Color.green.opacity(0.85))
      }
      .font(.system(size: terminalFontSize, design: .monospaced))
      .textSelection(.enabled)
    }
    .padding(12)
    .background(backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(borderColor, lineWidth: 1)
    )
  }
}

// MARK: - Agent Profile Row

private struct AgentProfileRow: View {
  let profile: SavedAgentProfile
  let availability: AgentAvailability.Details
  let dropPlacement: AgentDropPlacement?
  let onSetEnabled: (Bool) -> Void
  let onDisableOrRemove: () -> Void
  let onDrag: () -> NSItemProvider
  let onUpdate: (SavedAgentProfile) -> Void
  @State private var showEditor = false

  var body: some View {
    HStack(spacing: 10) {
      Toggle(
        "",
        isOn: Binding(
          get: { effectiveIsEnabled },
          set: { isEnabled in
            guard !isUnavailable else { return }
            onSetEnabled(isEnabled)
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
      .controlSize(.small)
      .frame(width: 16)
      .disabled(isEnableToggleDisabled)
      .help(
        isEnableToggleDisabled
          ? "Install \(profile.baseCommand) before enabling this agent."
          : profile.isEnabled
            ? "Disable agent in launch pickers." : "Enable agent in launch pickers."
      )

      rowInteractionContent
    }
    .frame(height: 48)
    .overlay(alignment: .top) {
      if dropPlacement == .before {
        insertionLine
      }
    }
    .overlay(alignment: .bottom) {
      if dropPlacement == .after {
        insertionLine
      }
    }
    .sheet(isPresented: $showEditor) {
      AgentEditorSheet(profile: profile, availability: availability) { updated in
        onUpdate(updated)
      }
    }
  }

  private var rowInteractionContent: some View {
    HStack(spacing: 10) {
      AgentIconView(icon: profile.icon)
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 20)
        .opacity(contentOpacity)

      VStack(alignment: .leading, spacing: 2) {
        Text(profile.name)
          .fontWeight(.medium)

        Text(rowDetailText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .opacity(contentOpacity)

      Spacer(minLength: 12)
      availabilityIndicator
    }
    .contentShape(Rectangle())
    .onDrag(onDrag) {
      Color.clear
        .frame(width: 1, height: 1)
    }
    .onTapGesture(count: 2) {
      showEditor = true
    }
    .contextMenu {
      Button {
        showEditor = true
      } label: {
        Label("Edit Agent...", systemImage: "pencil")
      }

      Divider()

      Button {
        onSetEnabled(!profile.isEnabled)
      } label: {
        Label(
          profile.isEnabled ? "Disable Agent" : "Enable Agent",
          systemImage: profile.isEnabled ? "slash.circle" : "checkmark.circle"
        )
      }
      .disabled(isEnableToggleDisabled)

      if !profile.isBuiltIn {
        Divider()

        Button(role: .destructive) {
          onDisableOrRemove()
        } label: {
          Label("Delete Agent", systemImage: "trash")
        }
      }
    }
    .accessibilityAction(named: Text("Edit Agent")) {
      showEditor = true
    }
  }

  private var contentOpacity: Double {
    isUnavailable ? 0.55 : 1
  }

  private var rowDetailText: String {
    switch availability.status {
    case .checking:
      if !profile.isEnabled {
        return "Disabled"
      }
      return "Checking for \(profile.baseCommand)..."
    case .available:
      if !profile.isEnabled {
        return "Disabled"
      }
      return "Installed"
    case .unavailable:
      return "\(profile.baseCommand) not found"
    }
  }

  @ViewBuilder
  private var availabilityIndicator: some View {
    switch availability.status {
    case .checking:
      if profile.isEnabled {
        ProgressView()
          .controlSize(.small)
          .frame(width: 20, height: 20)
          .help("Checking whether \(profile.baseCommand) is installed.")
      } else {
        EmptyView()
      }
    case .available:
      if profile.isEnabled {
        if let version = availability.version {
          Text(version)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(availableHelpText)
        } else {
          EmptyView()
        }
      } else {
        EmptyView()
      }
    case .unavailable:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .imageScale(.medium)
        .frame(width: 20, height: 20)
        .help("\(profile.baseCommand) was not found in your shell PATH.")
        .accessibilityLabel("Agent command not found")
        .accessibilityValue(profile.baseCommand)
    }
  }

  private var isEnableToggleDisabled: Bool {
    isUnavailable
  }

  private var effectiveIsEnabled: Bool {
    profile.isEnabled && !isUnavailable
  }

  private var isUnavailable: Bool {
    availability.status == .unavailable
  }

  private var insertionLine: some View {
    Rectangle()
      .fill(Color.accentColor)
      .frame(height: 2)
      .allowsHitTesting(false)
  }

  private var availableHelpText: String {
    if let resolvedPath = availability.resolvedPath {
      return "\(profile.baseCommand) found at \(resolvedPath)."
    }
    return "\(profile.baseCommand) is installed."
  }
}

private enum AgentDropPlacement: Equatable {
  case before
  case after
}

private struct AgentDropInsertion: Equatable {
  var profileID: String
  var placement: AgentDropPlacement
}

private struct AgentProfileDropDelegate: DropDelegate {
  let destinationProfileID: String
  let profiles: [SavedAgentProfile]
  @Binding var draggingAgentId: String?
  @Binding var dropInsertion: AgentDropInsertion?
  let move: (IndexSet, Int) -> Void

  func dropEntered(info: DropInfo) {
    updateInsertion(for: info)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    updateInsertion(for: info)
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    guard dropInsertion?.profileID == destinationProfileID else { return }
    dropInsertion = nil
  }

  func performDrop(info: DropInfo) -> Bool {
    defer {
      draggingAgentId = nil
      dropInsertion = nil
    }

    guard let draggingAgentId,
      draggingAgentId != destinationProfileID,
      let sourceIndex = profiles.firstIndex(where: { $0.id == draggingAgentId }),
      let destinationIndex = profiles.firstIndex(where: { $0.id == destinationProfileID })
    else { return false }

    let destination = moveDestination(
      sourceIndex: sourceIndex,
      destinationIndex: destinationIndex,
      placement: placement(for: info)
    )

    guard destination != sourceIndex, destination != sourceIndex + 1 else {
      return true
    }

    move(IndexSet(integer: sourceIndex), destination)
    return true
  }

  private func updateInsertion(for info: DropInfo) {
    guard let draggingAgentId,
      draggingAgentId != destinationProfileID
    else {
      dropInsertion = nil
      return
    }

    dropInsertion = AgentDropInsertion(
      profileID: destinationProfileID,
      placement: placement(for: info)
    )
  }

  private func placement(for info: DropInfo) -> AgentDropPlacement {
    info.location.y < 24 ? .before : .after
  }

  private func moveDestination(
    sourceIndex: Int,
    destinationIndex: Int,
    placement: AgentDropPlacement
  ) -> Int {
    switch placement {
    case .before:
      destinationIndex
    case .after:
      destinationIndex + 1
    }
  }
}

// MARK: - Agent Editor Sheet

private struct AgentEditorSheet: View {
  let profile: SavedAgentProfile
  let availability: AgentAvailability.Details
  let onSave: (SavedAgentProfile) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var editName: String
  @State private var editCommand: String
  @State private var editIsEnabled: Bool
  @State private var editYoloFlag: String
  @State private var attemptedSave = false

  private let labelWidth: CGFloat = 132
  private let fieldWidth: CGFloat = 340

  init(
    profile: SavedAgentProfile,
    availability: AgentAvailability.Details = .checking,
    onSave: @escaping (SavedAgentProfile) -> Void
  ) {
    self.profile = profile
    self.availability = availability
    self.onSave = onSave
    self._editName = State(initialValue: profile.name)
    self._editCommand = State(initialValue: profile.command)
    self._editIsEnabled = State(initialValue: profile.isEnabled)
    self._editYoloFlag = State(initialValue: profile.yoloFlag)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(editorTitle)
        .font(.headline)

      if profile.isBuiltIn {
        builtInConfigurationFields
      } else {
        customAgentFields
      }

      actionButtons
    }
    .padding(24)
    .frame(width: 550)
  }

  private var editorTitle: String {
    if profile.isBuiltIn {
      return "Configure Agent"
    }
    return profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "New Agent" : "Edit Agent"
  }

  private var trimmedName: String {
    editName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedCommand: String {
    editCommand.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedYoloFlag: String {
    editYoloFlag.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSave: Bool {
    (profile.isBuiltIn || !trimmedName.isEmpty) && !trimmedCommand.isEmpty
  }

  private func save() {
    guard canSave else { return }
    var updated = profile
    if let familyID = profile.familyID {
      let defaultProfile = familyID.defaultProfile
      updated.familyID = familyID
      updated.name = defaultProfile.name
      updated.command = defaultProfile.command
      updated.icon = defaultProfile.icon
      updated.yoloFlag = defaultProfile.yoloFlag
      updated.promptArgumentTemplate = defaultProfile.promptArgumentTemplate
      updated.resumeArgumentTemplate = defaultProfile.resumeArgumentTemplate
    } else {
      updated.name = trimmedName
      updated.familyID = nil
      updated.icon = "agent"
      updated.yoloFlag = trimmedYoloFlag
      updated.promptArgumentTemplate = ""
      updated.resumeArgumentTemplate = ""
    }
    if !profile.isBuiltIn {
      updated.command = trimmedCommand
    }
    updated.isEnabled = editIsEnabled
    onSave(updated)
    dismiss()
  }

  @ViewBuilder
  private var actionButtons: some View {
    HStack {
      Spacer()

      if profile.isBuiltIn {
        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      } else {
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Save") {
          attemptedSave = true
          save()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var builtInConfigurationFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      toggleField(
        "Enabled",
        isOn: immediateEnabledBinding,
        help: "Show this agent in launch pickers."
      )
      staticField("Command", value: familyDefaultCommand, isMonospaced: true)
      staticField("Status", value: availabilityLabel)
      if let version = availability.version {
        staticField("Version", value: version)
      }
    }
  }

  private var customAgentFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      editorField(
        "Name",
        text: $editName,
        prompt: "Codex",
        validationMessage: attemptedSave && trimmedName.isEmpty ? "Name is required." : nil
      )
      toggleField("Enabled", isOn: $editIsEnabled, help: "Show this agent in launch pickers.")
      editorField(
        "Command",
        text: $editCommand,
        prompt: "codex",
        isMonospaced: true,
        validationMessage: attemptedSave && trimmedCommand.isEmpty ? "Command is required." : nil
      )
      editorField(
        "Auto-approve",
        text: $editYoloFlag,
        prompt: "--yolo",
        isMonospaced: true,
        help: "Optional flag appended when auto-approve mode is enabled."
      )
    }
  }

  private var familyDefaultCommand: String {
    profile.familyID?.defaultProfile.command ?? "codex"
  }

  private var immediateEnabledBinding: Binding<Bool> {
    Binding(
      get: { editIsEnabled },
      set: { isEnabled in
        editIsEnabled = isEnabled
        saveBuiltInConfiguration()
      }
    )
  }

  private func saveBuiltInConfiguration() {
    guard let familyID = profile.familyID else { return }
    let defaultProfile = familyID.defaultProfile
    var updated = profile
    updated.familyID = familyID
    updated.name = defaultProfile.name
    updated.command = defaultProfile.command
    updated.icon = defaultProfile.icon
    updated.yoloFlag = defaultProfile.yoloFlag
    updated.promptArgumentTemplate = defaultProfile.promptArgumentTemplate
    updated.resumeArgumentTemplate = defaultProfile.resumeArgumentTemplate
    updated.isEnabled = editIsEnabled
    onSave(updated)
  }

  private var availabilityLabel: String {
    switch availability.status {
    case .checking:
      "Checking for \(familyDefaultCommand)..."
    case .available:
      if let resolvedPath = availability.resolvedPath {
        "Installed at \(resolvedPath)"
      } else {
        "Installed"
      }
    case .unavailable:
      "\(familyDefaultCommand) not found"
    }
  }

  @ViewBuilder
  private func staticField(
    _ label: String,
    value: String,
    isMonospaced: Bool = false
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .frame(width: labelWidth, alignment: .trailing)
        .foregroundStyle(.secondary)

      Text(value)
        .font(fieldFont(isMonospaced: isMonospaced))
        .foregroundStyle(.primary)
        .frame(width: fieldWidth, alignment: .leading)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private func toggleField(
    _ label: String,
    isOn: Binding<Bool>,
    help: String? = nil,
    caption: String? = nil
  ) -> some View {
    if let caption {
      HStack(alignment: .top, spacing: 12) {
        Text(label)
          .frame(width: labelWidth, alignment: .trailing)
          .foregroundStyle(.secondary)
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 5) {
          Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel(label)
            .help(help ?? "")

          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: fieldWidth, alignment: .leading)
      }
    } else {
      HStack(alignment: .center, spacing: 12) {
        Text(label)
          .frame(width: labelWidth, alignment: .trailing)
          .foregroundStyle(.secondary)

        Toggle("", isOn: isOn)
          .labelsHidden()
          .toggleStyle(.checkbox)
          .accessibilityLabel(label)
          .help(help ?? "")
          .frame(width: fieldWidth, alignment: .leading)
      }
    }
  }

  @ViewBuilder
  private func editorField(
    _ label: String,
    text: Binding<String>,
    prompt: String,
    isMonospaced: Bool = false,
    help: String? = nil,
    validationMessage: String? = nil
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .frame(width: labelWidth, alignment: .trailing)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 5) {
        TextField("", text: text, prompt: Text(prompt))
          .textFieldStyle(.roundedBorder)
          .font(fieldFont(isMonospaced: isMonospaced))
          .frame(width: fieldWidth)
          .accessibilityLabel(label)
          .help(help ?? "")

        if let validationMessage {
          Text(validationMessage)
            .font(.caption)
            .foregroundStyle(.red)
            .frame(width: fieldWidth, alignment: .leading)
        } else if let help {
          Text(help)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: fieldWidth, alignment: .leading)
        }
      }
    }
  }

  private func fieldFont(isMonospaced: Bool) -> Font {
    isMonospaced ? .system(.body, design: .monospaced) : .body
  }
}
