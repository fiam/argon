import AppKit
import SwiftUI

/// Displays an agent icon from the asset catalog, falling back to an SF Symbol.
struct AgentIconView: View {
  let icon: String
  var size: CGFloat = 16

  /// Known asset catalog names that have custom images.
  private static let assetNames: Set<String> = ["claude", "codex", "gemini"]

  var body: some View {
    if Self.assetNames.contains(icon), let nsImage = NSImage(named: icon) {
      Image(nsImage: nsImage)
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
    case "claude": "brain"
    case "codex": "terminal"
    case "gemini": "sparkles"
    default: "terminal"
    }
  }
}

struct SettingsView: View {
  @Environment(SavedAgentProfiles.self) private var savedAgents
  @Environment(AgentAvailability.self) private var agentAvailability
  @AppStorage("defaultDiffViewMode") private var defaultDiffViewMode = "unified"
  @AppStorage("diffFontSize") private var diffFontSize = 13.0
  @AppStorage("terminalFontSize") private var terminalFontSize = 12.0
  @AppStorage(WorktreeRootSettings.storageKey)
  private var worktreeRootPath = WorktreeRootSettings.defaultRootPath()
  @AppStorage(WorkspaceFinishedTerminalBehavior.storageKey)
  private var finishedTerminalBehavior = WorkspaceFinishedTerminalBehavior.autoClose.rawValue
  @State private var selectedAgentId: String?
  @State private var editingNewAgent = false

  var body: some View {
    TabView {
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }
      agentsTab
        .tabItem { Label("Agents", systemImage: "person.2") }
      appearanceTab
        .tabItem { Label("Appearance", systemImage: "textformat.size") }
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
    }
    .formStyle(.grouped)
    .padding()
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
    .padding()
    .sheet(isPresented: $editingNewAgent) {
      AgentEditorSheet(
        profile: SavedAgentProfile(
          id: "custom-\(UUID().uuidString.prefix(8))",
          name: "",
          command: "",
          icon: "terminal",
          yoloFlag: "",
          promptArgumentTemplate: ""
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

      Section("Terminal") {
        HStack {
          Text("Font size: \(Int(terminalFontSize))pt")
          Slider(value: $terminalFontSize, in: 10...24, step: 1)
        }
        Text("$ argon review --mode uncommitted")
          .font(.system(size: terminalFontSize, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
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

  init(profile: SavedAgentProfile, onSave: @escaping (SavedAgentProfile) -> Void) {
    self.profile = profile
    self.onSave = onSave
    self._editName = State(initialValue: profile.name)
    self._editCommand = State(initialValue: profile.command)
    self._editYoloFlag = State(initialValue: profile.yoloFlag)
    self._editPromptArgumentTemplate = State(initialValue: profile.promptArgumentTemplate)
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
