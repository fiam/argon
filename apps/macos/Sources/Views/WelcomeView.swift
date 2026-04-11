import SwiftUI

struct WelcomeView: View {
  @Environment(RecentProjects.self) private var recentProjects
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var isCreatingSession = false
  @State private var errorMessage: String?

  var body: some View {
    ZStack {
      WelcomeBackground()

      VStack(spacing: 18) {
        heroCard
        recentProjectsCard
        actionBar
      }
      .padding(20)
    }
    .frame(minWidth: 560, minHeight: 420)
    .onAppear {
      if let target = AppLaunchTarget.current() {
        recentProjects.add(repoRoot: target.repoRoot)
        openWindow(value: target)
        dismissWindow(id: "welcome")
      }
    }
  }

  private var heroCard: some View {
    HStack(spacing: 20) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 78, height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)

      VStack(alignment: .leading, spacing: 8) {
        Text("Argon")
          .font(.system(size: 34, weight: .bold, design: .rounded))
        Text("Native code review for coding agents")
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
        Text(
          "Review diffs, coordinate agent work, and jump back into recent repositories without leaving macOS."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)

        HStack(spacing: 8) {
          WelcomeBadge(icon: "arrow.left.arrow.right", label: "Diff Review")
          WelcomeBadge(icon: "text.bubble", label: "Inline Threads")
          WelcomeBadge(icon: "terminal", label: "CLI-Driven")
        }
      }

      Spacer(minLength: 0)
    }
    .padding(24)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              Color(nsColor: .windowBackgroundColor).opacity(0.92),
              Color.accentColor.opacity(0.10),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(Color.white.opacity(0.10), lineWidth: 1)
    )
  }

  private var recentProjectsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Recent Projects")
          .font(.headline)
        Spacer()
        Text("\(recentProjects.projects.count)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.white.opacity(0.06), in: Capsule())
      }

      if recentProjects.projects.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "folder.badge.plus")
            .font(.system(size: 24))
            .foregroundStyle(.secondary)
          Text("No recent projects yet")
            .font(.headline)
          Text(
            "Open a repository to start a review workspace. Your recent projects will appear here."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(spacing: 10) {
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
          .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(Color.white.opacity(0.08), lineWidth: 1)
    )
  }

  private var actionBar: some View {
    HStack(spacing: 12) {
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      } else {
        Text("Press Command-O to open a repository.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if let recent = recentProjects.projects.first {
        Button("Open Latest") {
          openProject(repoRoot: recent.repoRoot)
        }
        .buttonStyle(.bordered)
        .disabled(isCreatingSession)
      }

      Button("Open Directory...") {
        pickDirectory()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut("o", modifiers: .command)
      .disabled(isCreatingSession)

      if isCreatingSession {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 4)
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

private struct WelcomeBackground: View {
  var body: some View {
    Color(nsColor: .windowBackgroundColor)
      .overlay(alignment: .topLeading) {
        Circle()
          .fill(Color.accentColor.opacity(0.18))
          .frame(width: 280, height: 280)
          .blur(radius: 70)
          .offset(x: -80, y: -120)
      }
      .overlay(alignment: .topTrailing) {
        Circle()
          .fill(Color.blue.opacity(0.12))
          .frame(width: 240, height: 240)
          .blur(radius: 80)
          .offset(x: 80, y: -70)
      }
      .overlay(alignment: .bottomTrailing) {
        Circle()
          .fill(Color.cyan.opacity(0.10))
          .frame(width: 220, height: 220)
          .blur(radius: 90)
          .offset(x: 90, y: 120)
      }
      .ignoresSafeArea()
  }
}

private struct WelcomeBadge: View {
  let icon: String
  let label: String

  var body: some View {
    Label(label, systemImage: icon)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color.white.opacity(0.06), in: Capsule())
      .overlay(
        Capsule()
          .stroke(Color.white.opacity(0.08), lineWidth: 1)
      )
  }
}

private struct RecentProjectRow: View {
  let project: RecentProject
  let onOpen: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 14) {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
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
          Text(project.lastOpened, style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color.white.opacity(isHovered ? 0.08 : 0.04))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.white.opacity(isHovered ? 0.12 : 0.06), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovered = hovering
    }
  }
}
