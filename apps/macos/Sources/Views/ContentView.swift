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
                    ReviewLayout(session: session)
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

struct ReviewLayout: View {
    @Environment(AppState.self) private var appState
    let session: ReviewSession

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(session: session, fileCount: appState.files.count)
            Divider()
            NavigationSplitView {
                SidebarContent()
            } detail: {
                DiffDetailView()
            }
        }
    }
}

struct SidebarContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            List(appState.files, selection: $state.selectedFile) { file in
                FileRow(file: file)
                    .tag(file)
            }
            .listStyle(.sidebar)

            if let session = appState.session {
                Divider()
                ThreadsPanel(session: session)
            }
        }
        .frame(minWidth: 240)
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
