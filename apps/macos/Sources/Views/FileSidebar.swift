import SwiftUI

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
            Spacer()
            HStack(spacing: 2) {
                let added = file.hunks.flatMap(\.lines).filter { $0.kind == .added }.count
                let removed = file.hunks.flatMap(\.lines).filter { $0.kind == .removed }.count
                if added > 0 {
                    Text("+\(added)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if removed > 0 {
                    Text("-\(removed)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ThreadsPanel: View {
    @Environment(AppState.self) private var appState
    let session: ReviewSession

    var body: some View {
        if session.threads.isEmpty {
            VStack(spacing: 6) {
                Text("No comments yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(session.threads) { thread in
                        ThreadRow(thread: thread)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 200)
        }
    }
}

struct ThreadRow: View {
    let thread: ReviewThread

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                threadStateBadge
                if let anchor = thread.comments.first?.anchor,
                   let file = anchor.filePath {
                    Text(file)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            ForEach(thread.comments) { comment in
                HStack(alignment: .top, spacing: 4) {
                    Text(commentAuthorLabel(comment))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(comment.author == .reviewer ? .orange : .blue)
                    Text(comment.body)
                        .font(.caption2)
                        .lineLimit(2)
                }
            }
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var threadStateBadge: some View {
        let (label, color): (String, Color) = switch thread.state {
        case .open: ("Open", .orange)
        case .addressed: ("Addressed", .blue)
        case .resolved: ("Resolved", .green)
        }
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func commentAuthorLabel(_ comment: ReviewComment) -> String {
        if let name = comment.authorName { return name }
        return comment.author == .reviewer ? "reviewer" : "agent"
    }
}
