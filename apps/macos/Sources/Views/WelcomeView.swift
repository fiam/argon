import SwiftUI

struct WelcomeView: View {
  let launchRequest: AppLaunchTarget.LaunchRequest?
  @Environment(RecentProjects.self) private var recentProjects
  @Environment(WorkspaceWindowRegistry.self) private var workspaceWindowRegistry
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var isCreatingSession = false
  @State private var errorMessage: String?
  @State private var pendingLaunchRequest: AppLaunchTarget.LaunchRequest?
  @State private var selectedRecentProjectID: String?
  @State private var hoveredRecentProjectID: String?
  @State private var welcomeTip: WelcomeTip?

  init(launchRequest: AppLaunchTarget.LaunchRequest? = nil) {
    self.launchRequest = launchRequest
    self._pendingLaunchRequest = State(initialValue: launchRequest)
  }

  var body: some View {
    HStack(spacing: 0) {
      primaryPane

      Divider()
        .overlay(Color.black.opacity(0.06))

      recentProjectsPane
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .frame(minWidth: 940, minHeight: 560)
    .onAppear {
      recentProjects.pruneMissingProjects()
      if let launchRequest = pendingLaunchRequest {
        pendingLaunchRequest = nil
        switch launchRequest {
        case .workspace(let target):
          recentProjects.add(repoRoot: target.repoRoot)
          workspaceWindowRegistry.open(target: target) { target in
            openWindow(value: target)
          }
        case .review(let target):
          recentProjects.add(repoRoot: target.repoRoot)
          openWindow(value: target)
        }
        dismissWindow(id: "welcome")
        return
      } else {
        let restoredCount = workspaceWindowRegistry.restorePersistedWorkspacesIfNeeded { target in
          openWindow(value: target)
        }
        if restoredCount > 0 {
          dismissWindow(id: "welcome")
          return
        }
      }

      if welcomeTip == nil {
        welcomeTip = WelcomeTipRotator().nextTip()
      }
    }
  }

  private var primaryPane: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 40)

      VStack(spacing: 68) {
        appIdentity

        VStack(spacing: 12) {
          welcomeActionButton(
            "Open Repository or Worktree…",
            systemImage: "folder"
          ) {
            pickDirectory()
          }
          .keyboardShortcut("o", modifiers: .command)
          .disabled(isCreatingSession)

          if let welcomeTip {
            WelcomeTipCard(tip: welcomeTip)
          }

          if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(3)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .frame(width: 420)
          }
        }
      }

      Spacer(minLength: 42)
    }
    .frame(width: 560)
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var appIdentity: some View {
    VStack(spacing: 20) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 132, height: 132)

      VStack(spacing: 4) {
        Text("Argon")
          .font(.system(size: 48, weight: .semibold, design: .default))
        Text("Version \(appVersion)")
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var recentProjectsPane: some View {
    VStack(alignment: .leading, spacing: 0) {
      if recentProjects.projects.isEmpty {
        Spacer()

        VStack(spacing: 10) {
          Image(systemName: "folder")
            .font(.system(size: 24))
            .foregroundStyle(.secondary)
          Text("No recent projects")
            .font(.headline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)

        Spacer()
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(recentProjects.projects) { project in
              RecentProjectRow(
                project: project,
                isSelected: selectedRecentProjectID == project.id,
                isHovered: hoveredRecentProjectID == project.id,
                isDisabled: isCreatingSession,
                onHover: { isHovered in
                  if isHovered {
                    hoveredRecentProjectID = project.id
                  } else if hoveredRecentProjectID == project.id {
                    hoveredRecentProjectID = nil
                  }
                }
              ) {
                selectedRecentProjectID = project.id
              } onOpen: {
                openProject(repoRoot: project.repoRoot)
              }
              .contextMenu {
                Button("Remove from Recents") {
                  recentProjects.remove(repoRoot: project.repoRoot)
                }
              }
            }
          }
          .padding(.horizontal, 18)
          .padding(.vertical, 20)
        }
        .scrollIndicators(.hidden)
      }
    }
    .frame(minWidth: 380, maxWidth: .infinity)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(recentProjectsPaneBackground)
  }

  private var recentProjectsPaneBackground: Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark =
          appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
          ? NSColor(calibratedWhite: 0.13, alpha: 1)
          : NSColor(calibratedWhite: 0.965, alpha: 1)
      })
  }

  private func welcomeActionButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: systemImage)
          .font(.system(size: 20, weight: .semibold))
          .frame(width: 24, height: 24)
          .foregroundStyle(.secondary)

        Text(title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        Spacer(minLength: 0)

        ZStack {
          Text("⌘O")
            .font(.caption.weight(.semibold))
            .monospaced()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              Color.primary.opacity(0.05),
              in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .opacity(isCreatingSession ? 0 : 1)

          ProgressView()
            .controlSize(.small)
            .opacity(isCreatingSession ? 1 : 0)
        }
        .frame(width: 42, height: 24)
      }
      .padding(.horizontal, 18)
      .frame(width: 420, height: 58)
      .background(
        Color.primary.opacity(0.06),
        in: Capsule()
      )
    }
    .buttonStyle(.plain)
  }

  private func pickDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a Git repository or worktree"

    guard panel.runModal() == .OK, let url = panel.url else { return }
    openProject(repoRoot: url.path)
  }

  private func openProject(repoRoot: String) {
    guard !isCreatingSession else { return }
    isCreatingSession = true
    errorMessage = nil

    Task {
      do {
        let target = try await Task.detached {
          try GitService.resolveWorkspaceTarget(path: repoRoot)
        }.value

        recentProjects.add(repoRoot: target.repoRoot)
        await MainActor.run {
          workspaceWindowRegistry.open(target: target) { target in
            openWindow(value: target)
          }
        }
      } catch {
        errorMessage = error.localizedDescription
      }
      isCreatingSession = false
    }
  }
}

extension WelcomeView {
  fileprivate var appVersion: String {
    AppBundleVersion.displayVersion()
  }
}

private struct WelcomeTipCard: View {
  let tip: WelcomeTip

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "lightbulb")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 3) {
        Text(tip.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(tip.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(width: 420, alignment: .leading)
    .background(
      Color.primary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
  }
}

private struct RecentProjectRow: View {
  let project: RecentProject
  let isSelected: Bool
  let isHovered: Bool
  let isDisabled: Bool
  let onHover: (Bool) -> Void
  let onSelect: () -> Void
  let onOpen: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(projectIconFill)
        .frame(width: 36, height: 36)
        .overlay {
          Image(systemName: "folder.fill")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(projectIconForeground)
        }

      VStack(alignment: .leading, spacing: 2) {
        Text(project.repoName)
          .font(.headline)
          .fontWeight(.medium)
          .lineLimit(1)
        Text(displayPath)
          .font(.caption.monospaced())
          .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .layoutPriority(1)

      Spacer()
    }
    .foregroundStyle(isSelected ? Color.white : Color.primary)
    .padding(.horizontal, 14)
    .frame(height: 56)
    .background(
      rowBackground,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .opacity(isDisabled ? 0.62 : 1)
    .onHover(perform: onHover)
    .onTapGesture(count: 2) {
      guard !isDisabled else { return }
      onOpen()
    }
    .onTapGesture(count: 1) {
      guard !isDisabled else { return }
      onSelect()
    }
  }

  private var rowBackground: Color {
    if isSelected {
      return Color.accentColor
    }
    if isHovered {
      return Color.primary.opacity(0.06)
    }
    return .clear
  }

  private var projectIconFill: Color {
    if isSelected {
      return .white.opacity(0.18)
    }
    return Color.accentColor.opacity(0.14)
  }

  private var projectIconForeground: Color {
    if isSelected {
      return .white
    }
    return Color.accentColor
  }

  private var displayPath: String {
    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    if project.repoRoot == homePath {
      return "~"
    }
    if project.repoRoot.hasPrefix(homePath + "/") {
      return "~" + project.repoRoot.dropFirst(homePath.count)
    }
    return project.repoRoot
  }
}
