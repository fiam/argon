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
    .controlSize(.small)
    .disabled(appState.session?.status == .approved || appState.session?.status == .closed)
    .sheet(isPresented: $showLaunchSheet) {
      AgentLaunchSheet(isPresented: $showLaunchSheet)
    }
  }
}

struct AgentLaunchSheet: View {
  @Environment(AppState.self) private var appState
  @Binding var isPresented: Bool
  @State private var savedAgents = SavedAgentProfiles()
  @State private var detectedStatus: [String: Bool] = [:]
  @State private var selectedAgentId: String?
  @State private var yoloMode = false
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
        Text("Agent")
          .font(.callout)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 6) {
          ForEach(savedAgents.profiles) { profile in
            let detected = detectedStatus[profile.id] ?? false
            AgentPickerCard(
              profile: profile,
              isDetected: detected,
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
        }

        if useCustom {
          TextField("Command (e.g. claude --dangerously-skip-permissions)", text: $customCommand)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
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

      // Actions
      HStack {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)

        Button("Launch") {
          launch()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canLaunch)
      }
    }
    .padding(24)
    .frame(width: 500)
    .onAppear {
      // Pre-compute detection status
      for profile in savedAgents.profiles {
        let baseCmd = profile.command.components(separatedBy: " ").first ?? profile.command
        detectedStatus[profile.id] = AgentDetector.commandExists(baseCmd)
      }
      // Select first detected agent
      for profile in savedAgents.profiles {
        if detectedStatus[profile.id] == true {
          selectedAgentId = profile.id
          return
        }
      }
      selectedAgentId = savedAgents.profiles.first?.id
    }
  }

  private var canLaunch: Bool {
    if useCustom {
      return !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return selectedAgentId != nil
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
      let cmd = saved.fullCommand(yolo: yoloMode)
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
      focusPrompt: focus.isEmpty ? nil : focus
    )
    isPresented = false
  }
}

struct AgentPickerCard: View {
  let profile: SavedAgentProfile
  let isDetected: Bool
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
          if !isDetected {
            Text("not installed")
              .font(.system(size: 9))
              .foregroundStyle(.orange)
          }
        }
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity)
      .background(isSelected ? Color.blue.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
      .foregroundStyle(isSelected ? .blue : isDetected ? .primary : .secondary)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isSelected ? Color.blue.opacity(0.4) : Color(nsColor: .separatorColor), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}
