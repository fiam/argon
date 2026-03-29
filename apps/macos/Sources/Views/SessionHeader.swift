import SwiftUI

struct SessionHeader: View {
    @Environment(AppState.self) private var appState
    let session: ReviewSession
    let fileCount: Int
    @State private var showSubmitSheet = false
    @State private var submitSummary = ""
    @State private var submitOutcome: String = "commented"

    var body: some View {
        HStack(spacing: 16) {
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

            if session.status != .approved && session.status != .closed {
                HandoffButton()
                Divider().frame(height: 16)
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
        .sheet(isPresented: $showSubmitSheet) {
            SubmitReviewSheet(
                draftCount: appState.pendingDrafts.count,
                outcome: $submitOutcome,
                summary: $submitSummary,
                onSubmit: {
                    appState.submitReview(
                        outcome: submitOutcome,
                        summary: submitSummary.isEmpty ? nil : submitSummary
                    )
                    showSubmitSheet = false
                    submitSummary = ""
                    submitOutcome = "commented"
                },
                onCancel: {
                    showSubmitSheet = false
                    submitSummary = ""
                }
            )
        }
        .onAppear {
            appState.reloadDrafts()
        }
    }

    @ViewBuilder
    private var reviewActions: some View {
        HStack(spacing: 8) {
            // Pending drafts badge
            if !appState.pendingDrafts.isEmpty {
                Text("\(appState.pendingDrafts.count) pending")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
            }

            Button {
                submitOutcome = "approved"
                showSubmitSheet = true
            } label: {
                Label("Submit Review", systemImage: "paperplane")
            }
            .controlSize(.small)
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

struct SubmitReviewSheet: View {
    let draftCount: Int
    @Binding var outcome: String
    @Binding var summary: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Submit Review")
                .font(.title2)
                .fontWeight(.semibold)

            if draftCount > 0 {
                Text("\(draftCount) pending comment\(draftCount == 1 ? "" : "s") will be submitted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No pending comments. You can still submit a decision.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Decision:", selection: $outcome) {
                Text("Approve").tag("approved")
                Text("Request Changes").tag("changes-requested")
                Text("Comment").tag("commented")
            }
            .pickerStyle(.segmented)

            Text("Summary (optional):")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $summary)
                .font(.system(.body, design: .monospaced))
                .frame(width: 440, height: 70)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(submitLabel) {
                    onSubmit()
                }
                .keyboardShortcut(.defaultAction)
                .tint(outcome == "approved" ? .green : outcome == "changes-requested" ? .orange : .blue)
            }
        }
        .padding(24)
    }

    private var submitLabel: String {
        switch outcome {
        case "approved": "Approve"
        case "changes-requested": "Request Changes"
        default: "Submit"
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

struct DiffStatView: View {
    let files: [FileDiff]

    private var added: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .added }.count
    }

    private var removed: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .removed }.count
    }

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
