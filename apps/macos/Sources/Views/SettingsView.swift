import AppKit
import SwiftUI

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

  @Environment(\.colorScheme) private var colorScheme
  @Environment(SavedAgentProfiles.self) private var savedAgents
  @Environment(AgentAvailability.self) private var agentAvailability
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
  @AppStorage(WorktreeMergeStrategySettings.defaultStrategyStorageKey)
  private var defaultWorktreeMergeStrategy = WorktreeMergeStrategy.mergeCommit.rawValue
  @State private var selectedAgentId: String?
  @State private var editingNewAgent = false
  @State private var ghosttyConfigurationDraft = ""
  @State private var appliedGhosttyConfigurationText = ""
  @State private var didLoadGhosttyConfigurationDraft = false
  @State private var terminalPreviewAppearance: TerminalPreviewAppearance = .dark
  @State private var didInitializeTerminalPreviewAppearance = false

  var body: some View {
    TabView {
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }
      agentsTab
        .tabItem { Label("Agents", systemImage: "person.2") }
      appearanceTab
        .tabItem { Label("Appearance", systemImage: "textformat.size") }
      terminalTab
        .tabItem { Label("Terminal", systemImage: "terminal") }
    }
    .frame(width: 550, height: 400)
  }

  private var generalTab: some View {
    Form {
      Section("Diff View") {
        Picker("Default mode", selection: $defaultDiffViewMode) {
          Text("Unified").tag("unified")
          Text("Side by Side").tag("sideBySide")
        }
        .pickerStyle(.segmented)
      }

      Section("Workspace") {
        Toggle("Close finished terminals automatically", isOn: autoCloseFinishedTerminalsBinding)
          .help(selectedFinishedTerminalBehavior.helpText)
      }

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

      Section("Finalize") {
        Picker("Default merge style", selection: $defaultWorktreeMergeStrategy) {
          ForEach(WorktreeMergeStrategy.allCases) { strategy in
            Text(strategy.menuTitle)
              .tag(strategy.rawValue)
          }
        }
        .pickerStyle(.menu)
      }
    }
    .formStyle(.grouped)
    .settingsTabInsets()
  }

  // MARK: - Agents Tab

  private var agentsTab: some View {
    VStack(spacing: 0) {
      List(selection: $selectedAgentId) {
        ForEach(savedAgents.profiles) { profile in
          AgentProfileRow(profile: profile, status: agentAvailability.status(for: profile)) {
            updated in
            savedAgents.update(updated)
          }
        }
        .onDelete { offsets in
          savedAgents.remove(at: offsets)
        }
        .onMove { source, destination in
          savedAgents.move(from: source, to: destination)
        }
      }
      .listStyle(.bordered(alternatesRowBackgrounds: true))

      // HIG-style segmented +/- button bar
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
            if let id = selectedAgentId {
              savedAgents.remove(id: id)
              selectedAgentId = nil
            }
          } label: {
            Image(systemName: "minus")
              .frame(width: 28, height: 22)
              .contentShape(Rectangle())
          }
          .disabled(selectedAgentId == nil)
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

  // MARK: - Appearance Tab

  private var appearanceTab: some View {
    Form {
      Section("Diff") {
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
            TextEditor(text: $ghosttyConfigurationDraft)
              .font(.system(.body, design: .monospaced))
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
  let status: AgentAvailability.Status
  let onUpdate: (SavedAgentProfile) -> Void
  @State private var showEditor = false

  var body: some View {
    HStack {
      AgentIconView(icon: profile.icon)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(profile.name)
          .fontWeight(.medium)
        HStack(spacing: 4) {
          Text(profile.command)
            .font(.caption)
            .foregroundStyle(.secondary)
          if !profile.yoloFlag.isEmpty {
            Text(profile.yoloFlag)
              .font(.caption2)
              .foregroundStyle(.orange)
          }
        }
        .lineLimit(1)
        if !profile.promptArgumentTemplate.isEmpty {
          Text(profile.promptArgumentTemplate)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if !profile.resumeArgumentTemplate.isEmpty {
          Text(profile.resumeArgumentTemplate)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
      Text(statusLabel)
        .font(.caption2)
        .foregroundStyle(statusColor)
      Button {
        showEditor = true
      } label: {
        Image(systemName: "pencil")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .sheet(isPresented: $showEditor) {
      AgentEditorSheet(profile: profile) { updated in
        onUpdate(updated)
      }
    }
  }

  private var statusLabel: String {
    switch status {
    case .checking:
      "checking"
    case .available:
      "available"
    case .unavailable:
      "missing"
    }
  }

  private var statusColor: Color {
    switch status {
    case .checking:
      .secondary
    case .available:
      .green
    case .unavailable:
      .orange
    }
  }
}

// MARK: - Agent Editor Sheet

private struct AgentEditorSheet: View {
  let profile: SavedAgentProfile
  let onSave: (SavedAgentProfile) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var editName: String
  @State private var editCommand: String
  @State private var editYoloFlag: String
  @State private var editPromptArgumentTemplate: String
  @State private var editResumeArgumentTemplate: String

  init(profile: SavedAgentProfile, onSave: @escaping (SavedAgentProfile) -> Void) {
    self.profile = profile
    self.onSave = onSave
    self._editName = State(initialValue: profile.name)
    self._editCommand = State(initialValue: profile.command)
    self._editYoloFlag = State(initialValue: profile.yoloFlag)
    self._editPromptArgumentTemplate = State(initialValue: profile.promptArgumentTemplate)
    self._editResumeArgumentTemplate = State(initialValue: profile.resumeArgumentTemplate)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Edit Agent")
        .font(.headline)

      Form {
        TextField("Name", text: $editName)
        TextField("Command", text: $editCommand)
          .font(.system(.body, design: .monospaced))
        TextField("Auto-approve flag", text: $editYoloFlag)
          .font(.system(.body, design: .monospaced))
        Text("Leave empty if the agent doesn't support an auto-approve mode.")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("Prompt argument template", text: $editPromptArgumentTemplate)
          .font(.system(.body, design: .monospaced))
        Text(
          "Use {{prompt}} where the quoted prompt should be inserted. Leave empty to append the prompt as the final argument."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        TextField("Resume argument template", text: $editResumeArgumentTemplate)
          .font(.system(.body, design: .monospaced))
        Text(
          "Use {{session_id}} where the quoted session ID should be inserted. Leave empty to disable resume-on-restore for this agent."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Save") {
          var updated = profile
          updated.name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
          updated.command = editCommand.trimmingCharacters(in: .whitespacesAndNewlines)
          updated.yoloFlag = editYoloFlag.trimmingCharacters(in: .whitespacesAndNewlines)
          updated.promptArgumentTemplate = editPromptArgumentTemplate.trimmingCharacters(
            in: .whitespacesAndNewlines
          )
          updated.resumeArgumentTemplate = editResumeArgumentTemplate.trimmingCharacters(
            in: .whitespacesAndNewlines
          )
          if !updated.name.isEmpty && !updated.command.isEmpty {
            onSave(updated)
          }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || editCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
    .padding(20)
    .frame(width: 400)
  }
}
