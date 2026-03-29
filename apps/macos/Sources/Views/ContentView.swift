import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isLoading {
                ProgressView("Loading session...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = appState.errorMessage {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Something went wrong",
                    detail: error
                )
            } else if let session = appState.session {
                if appState.files.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "No changes",
                        detail: "No differences found between \(session.baseRef) and working tree."
                    )
                } else {
                    NavigationSplitView {
                        FileSidebar()
                    } detail: {
                        DiffDetailView()
                    }
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            SessionInfoBar(session: session, fileCount: appState.files.count)
                        }
                    }
                }
            } else {
                EmptyStateView(
                    icon: "arrow.right.circle",
                    title: "No session",
                    detail: "Launch from the terminal: argon . (in a git repo)"
                )
            }
        }
        .onAppear {
            appState.loadSession()
        }
        .navigationTitle(windowTitle)
    }

    private var windowTitle: String {
        guard let session = appState.session else { return "Argon" }
        let repo = URL(fileURLWithPath: session.repoRoot).lastPathComponent
        return "Argon — \(repo)"
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2)
                .fontWeight(.medium)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SessionInfoBar: View {
    let session: ReviewSession
    let fileCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Label(modeLabel, systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let summary = session.changeSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(fileCount) files changed")
                .font(.caption)
                .foregroundStyle(.secondary)
            StatusBadge(status: session.status)
        }
    }

    private var modeLabel: String {
        switch session.mode {
        case .branch: "\(session.baseRef)...\(session.headRef)"
        case .commit: "\(session.baseRef) to working tree"
        case .uncommitted: "uncommitted changes"
        }
    }
}
