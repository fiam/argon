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

                Text("\(fileCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = session.changeSummary {
                Divider().frame(height: 16)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

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
            VStack(alignment: .leading, spacing: 8) {
                Text("Global Comment")
                    .font(.headline)
                TextEditor(text: $commentText)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 360, height: 100)
                    .border(Color(nsColor: .separatorColor))
                HStack {
                    Spacer()
                    Button("Cancel") {
                        showPopover = false
                        commentText = ""
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Submit") {
                        guard !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        appState.addComment(message: commentText)
                        showPopover = false
                        commentText = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
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
