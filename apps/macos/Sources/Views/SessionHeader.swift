import SwiftUI

struct SessionHeader: View {
    @Environment(AppState.self) private var appState
    let session: ReviewSession
    let fileCount: Int
    @State private var showDecisionSheet = false
    @State private var decisionSummary = ""
    @State private var pendingOutcome: String?

    var body: some View {
        HStack(spacing: 16) {
            // Left: session info
            HStack(spacing: 12) {
                StatusBadge(status: session.status)

                Label(modeLabel, systemImage: modeIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DiffStatView(files: appState.files)
            }

            if let summary = session.changeSummary {
                Divider().frame(height: 16)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Handoff command
            if session.status != .approved && session.status != .closed {
                HandoffButton()
                Divider().frame(height: 16)
            }

            // Right: review actions
            if session.status != .approved && session.status != .closed {
                reviewActions
            } else if session.status == .approved {
                Label("Approved", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)
            } else {
                Label("Closed", systemImage: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showDecisionSheet) {
            DecisionSheet(
                outcome: pendingOutcome ?? "approved",
                summary: $decisionSummary,
                onSubmit: {
                    if let outcome = pendingOutcome {
                        appState.submitDecision(outcome: outcome, summary: decisionSummary.isEmpty ? nil : decisionSummary)
                    }
                    showDecisionSheet = false
                    decisionSummary = ""
                },
                onCancel: {
                    showDecisionSheet = false
                    decisionSummary = ""
                }
            )
        }
    }

    @ViewBuilder
    private var reviewActions: some View {
        HStack(spacing: 8) {
            CommentButton()

            Button {
                pendingOutcome = "changes-requested"
                showDecisionSheet = true
            } label: {
                Label("Request Changes", systemImage: "arrow.uturn.backward")
            }
            .controlSize(.small)

            Button {
                pendingOutcome = "approved"
                showDecisionSheet = true
            } label: {
                Label("Approve", systemImage: "checkmark")
            }
            .controlSize(.small)
            .tint(.green)
        }
    }

    private var modeLabel: String {
        switch session.mode {
        case .branch: "\(shorten(session.baseRef))...\(shorten(session.headRef))"
        case .commit: "\(shorten(session.baseRef)) → working tree"
        case .uncommitted: "uncommitted changes"
        }
    }

    private var modeIcon: String {
        switch session.mode {
        case .branch: "arrow.triangle.branch"
        case .commit: "clock.arrow.circlepath"
        case .uncommitted: "pencil.and.outline"
        }
    }

    private func shorten(_ ref: String) -> String {
        if ref.count > 20 { return String(ref.prefix(17)) + "..." }
        return ref
    }
}

struct CommentButton: View {
    @Environment(AppState.self) private var appState
    @State private var showPopover = false
    @State private var commentText = ""

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Label("Comment", systemImage: "text.bubble")
        }
        .controlSize(.small)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            CommentEditorPopover(
                title: "Comment",
                commentText: $commentText,
                onSubmit: {
                    appState.addComment(message: commentText)
                    showPopover = false
                    commentText = ""
                },
                onCancel: {
                    showPopover = false
                    commentText = ""
                }
            )
        }
    }
}

struct DecisionSheet: View {
    let outcome: String
    @Binding var summary: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(outcome == "approved" ? "Approve Review" : "Request Changes")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Optional summary:")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $summary)
                .font(.system(.body, design: .monospaced))
                .frame(width: 400, height: 80)
                .border(Color(nsColor: .separatorColor))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(outcome == "approved" ? "Approve" : "Request Changes") {
                    onSubmit()
                }
                .keyboardShortcut(.defaultAction)
                .tint(outcome == "approved" ? .green : .orange)
            }
        }
        .padding(24)
    }
}

struct DiffStatView: View {
    let files: [FileDiff]

    private var added: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .added }.count
    }

    private var removed: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .removed }.count
    }

    private var total: Int { added + removed }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(files.count) files")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("+\(added)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.green)

            Text("-\(removed)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.red)

            // GitHub-style block bar
            DiffStatBar(added: added, removed: removed)
        }
    }
}

struct DiffStatBar: View {
    let added: Int
    let removed: Int
    private let blockCount = 5
    private let blockSize: CGFloat = 8

    var body: some View {
        HStack(spacing: 1) {
            let total = added + removed
            let greenBlocks = total > 0 ? max(0, min(blockCount, Int(round(Double(added) / Double(total) * Double(blockCount))))) : 0
            let redBlocks = total > 0 ? blockCount - greenBlocks : 0

            ForEach(0..<greenBlocks, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.green)
                    .frame(width: blockSize, height: blockSize)
            }
            ForEach(0..<redBlocks, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.red)
                    .frame(width: blockSize, height: blockSize)
            }
            if total == 0 {
                ForEach(0..<blockCount, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: blockSize, height: blockSize)
                }
            }
        }
    }
}

struct HandoffButton: View {
    @Environment(AppState.self) private var appState
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(appState.handoffCommand, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy Agent Command", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
        .help(appState.handoffCommand)
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
