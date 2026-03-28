import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isLoading {
                ProgressView("Loading session...")
            } else if let error = appState.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.session != nil {
                NavigationSplitView {
                    FileSidebar()
                } detail: {
                    DiffDetailView()
                }
            } else {
                Text("No session loaded")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let mode = session.mode.rawValue
        return "Argon — \(repo) (\(mode))"
    }
}
