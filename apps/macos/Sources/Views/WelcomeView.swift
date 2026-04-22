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

  init(launchRequest: AppLaunchTarget.LaunchRequest? = nil) {
    self.launchRequest = launchRequest
    self._pendingLaunchRequest = State(initialValue: launchRequest)
  }

  var body: some View {
    HStack(spacing: 0) {
      primaryPane

      Divider()
        .overlay(Color.white.opacity(0.05))

      recentProjectsPane
    }
    .background(WelcomeBackground())
    .frame(minWidth: 760, minHeight: 560)
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
      } else {
        let restoredCount = workspaceWindowRegistry.restorePersistedWorkspacesIfNeeded { target in
          openWindow(value: target)
        }
        if restoredCount > 0 {
          dismissWindow(id: "welcome")
        }
      }
    }
  }

  private var primaryPane: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)

      VStack(spacing: 18) {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .fill(Color.accentColor.opacity(0.10))
          .frame(width: 156, height: 156)
          .overlay {
            Image(nsImage: NSApp.applicationIconImage)
              .resizable()
              .interpolation(.high)
              .frame(width: 112, height: 112)
          }

        VStack(spacing: 4) {
          Text("Argon")
            .font(.system(size: 40, weight: .semibold, design: .default))
          Text("Version \(appVersion)")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
        }

        VStack(spacing: 12) {
          welcomeActionButton(
            "Open Repository or Worktree…",
            systemImage: "folder"
          ) {
            pickDirectory()
          }
          .keyboardShortcut("o", modifiers: .command)
          .disabled(isCreatingSession)
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }

        if isCreatingSession {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 40)

      Spacer(minLength: 0)

      Text("Press Command-O to open a repository or worktree.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 18)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var recentProjectsPane: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Recent Projects")
        .font(.headline)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)

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
          LazyVStack(spacing: 0) {
            ForEach(Array(recentProjects.projects.enumerated()), id: \.element.id) {
              index, project in
              VStack(spacing: 0) {
                RecentProjectRow(project: project) {
                  openProject(repoRoot: project.repoRoot)
                }
                .contextMenu {
                  Button("Remove from Recents") {
                    recentProjects.remove(repoRoot: project.repoRoot)
                  }
                }

                if index < recentProjects.projects.count - 1 {
                  Divider()
                    .overlay(Color.white.opacity(0.04))
                    .padding(.leading, 68)
                    .padding(.trailing, 16)
                }
              }
            }
          }
          .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
      }
    }
    .frame(width: 340)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(Color.white.opacity(0.03))
  }

  private func welcomeActionButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 20) {
        Image(systemName: systemImage)
          .font(.system(size: 20, weight: .semibold))
          .frame(width: 24, height: 24)
          .foregroundStyle(.secondary)

        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 18)
      .frame(width: 360)
      .background(
        Color.white.opacity(0.04),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
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
    let bundle = Bundle.main
    return (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.1.0"
  }
}

private struct WelcomeBackground: View {
  var body: some View {
    Color(nsColor: .windowBackgroundColor)
      .overlay(alignment: .top) {
        LinearGradient(
          colors: [
            Color.accentColor.opacity(0.08),
            .clear,
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: 140)
      }
      .ignoresSafeArea()
  }
}

private struct RecentProjectRow: View {
  let project: RecentProject
  let onOpen: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 14) {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.accentColor.opacity(isHovered ? 0.22 : 0.14))
          .frame(width: 38, height: 38)
          .overlay {
            Image(systemName: "folder.fill")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(Color.accentColor)
          }

        VStack(alignment: .leading, spacing: 2) {
          Text(project.repoName)
            .fontWeight(.medium)
          Text(project.repoRoot)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 4) {
          Text("Last opened")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
          Text(RecentProjectLastOpenedFormatter.label(for: project.lastOpened))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(Color.white.opacity(isHovered ? 0.04 : 0.0))
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovered = hovering
    }
  }
}
