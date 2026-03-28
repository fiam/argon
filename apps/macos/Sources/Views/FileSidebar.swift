import SwiftUI

struct FileSidebar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        List(appState.files, selection: $state.selectedFile) { file in
            FileRow(file: file)
                .tag(file)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        .toolbar {
            if let session = appState.session {
                ToolbarItem(placement: .automatic) {
                    StatusBadge(status: session.status)
                }
            }
        }
    }
}

struct FileRow: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(file.displayPath)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Text(label)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .awaitingReviewer: "Awaiting Review"
        case .awaitingAgent: "Awaiting Agent"
        case .approved: "Approved"
        case .closed: "Closed"
        }
    }

    private var color: Color {
        switch status {
        case .awaitingReviewer: .orange
        case .awaitingAgent: .blue
        case .approved: .green
        case .closed: .secondary
        }
    }
}
