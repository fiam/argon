import SwiftUI

struct WelcomeView: View {
  @Environment(RecentProjects.self) private var recentProjects
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var isCreatingSession = false
  @State private var errorMessage: String?

  private static let cliTarget: ReviewTarget? = {
    let args = ProcessInfo.processInfo.arguments
    var sessionId: String?
    var repoRoot: String?
    var i = 1
    while i < args.count {
      switch args[i] {
      case "--session-id" where i + 1 < args.count:
        sessionId = args[i + 1]
        i += 2
      case "--repo-root" where i + 1 < args.count:
        repoRoot = args[i + 1]
        i += 2
      default:
        i += 1
      }
    }
    if let sessionId, let repoRoot {
      return ReviewTarget(sessionId: sessionId, repoRoot: repoRoot)
    }
    return nil
  }()

  var body: some View {
    VStack(spacing: 0) {
      // Header
      VStack(spacing: 8) {
        Image(systemName: "doc.text.magnifyingglass")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
        Text("Argon")
          .font(.largeTitle)
          .fontWeight(.bold)
        Text("Code Review")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 32)
      .padding(.bottom, 24)

      Divider()

      // Recent projects
      if recentProjects.projects.isEmpty {
        Spacer()
        Text("No recent projects")
          .foregroundStyle(.tertiary)
        Spacer()
      } else {
        List {
          ForEach(recentProjects.projects) { project in
            RecentProjectRow(project: project) {
              openProject(repoRoot: project.repoRoot)
            }
            .contextMenu {
              Button("Remove from Recents") {
                recentProjects.remove(repoRoot: project.repoRoot)
              }
            }
          }
        }
        .listStyle(.plain)
      }

      Divider()

      // Actions
      HStack {
        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
          Spacer()
        }

        Spacer()

        Button("Open Directory...") {
          pickDirectory()
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(isCreatingSession)

        if isCreatingSession {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding()
    }
    .frame(minWidth: 400, minHeight: 300)
    .onAppear {
      if let target = Self.cliTarget {
        recentProjects.add(repoRoot: target.repoRoot)
        openWindow(value: target)
        dismissWindow(id: "welcome")
      }
    }
  }

  private func pickDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a Git repository to review"

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
          try ArgonCLI.createSession(repoRoot: repoRoot)
        }.value

        recentProjects.add(repoRoot: target.repoRoot)
        openWindow(value: target)
      } catch {
        errorMessage = error.localizedDescription
      }
      isCreatingSession = false
    }
  }
}

private struct RecentProjectRow: View {
  let project: RecentProject
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack {
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(project.repoName)
            .fontWeight(.medium)
          Text(project.repoRoot)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        Text(project.lastOpened, style: .relative)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
