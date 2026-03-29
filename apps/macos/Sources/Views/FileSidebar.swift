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
    @State private var showCommentPopover = false
    @State private var commentText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Pending drafts
            if !appState.pendingDrafts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Pending Review")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.purple)
                        Spacer()
                        Text("\(appState.pendingDrafts.count)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                    ForEach(appState.pendingDrafts) { draft in
                        DraftRow(draft: draft)
                    }
                }
                .padding(8)
                Divider()
            }

            // Add comment button
            if session.status != .approved && session.status != .closed {
                Button {
                    showCommentPopover = true
                } label: {
                    Label("Add Comment", systemImage: "plus.bubble")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                .popover(isPresented: $showCommentPopover, arrowEdge: .trailing) {
                    CommentEditorPopover(
                        title: "Comment",
                        commentText: $commentText,
                        onSubmit: {
                            appState.addDraft(message: commentText)
                            showCommentPopover = false
                            commentText = ""
                        },
                        onCancel: {
                            showCommentPopover = false
                            commentText = ""
                        }
                    )
                }
            }

            // Submitted threads
            if !session.threads.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text("Threads")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        ForEach(session.threads) { thread in
                            ThreadRow(thread: thread)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 200)
            } else if appState.pendingDrafts.isEmpty {
                Text("No comments yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
        }
    }
}

struct DraftRow: View {
    @Environment(AppState.self) private var appState
    let draft: DraftComment

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                if let file = draft.anchor.filePath {
                    HStack(spacing: 2) {
                        Text(file)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let line = draft.anchor.lineNew {
                            Text(":\(line)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(draft.body)
                    .font(.caption2)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                appState.deleteDraft(draft.id.uuidString)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(Color.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
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
