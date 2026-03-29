import SwiftUI

struct DiffDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let file = appState.selectedFile {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DiffFileHeader(file: file)
                    ForEach(file.hunks) { hunk in
                        DiffHunkView(hunk: hunk, filePath: file.newPath)
                    }
                }
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            Text("Select a file")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DiffFileHeader: View {
    let file: FileDiff

    var body: some View {
        HStack {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(file.displayPath)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
            Spacer()
            Text("+\(addedCount) -\(removedCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var addedCount: Int {
        file.hunks.flatMap(\.lines).filter { $0.kind == .added }.count
    }

    private var removedCount: Int {
        file.hunks.flatMap(\.lines).filter { $0.kind == .removed }.count
    }
}

struct DiffHunkView: View {
    let hunk: DiffHunk
    let filePath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(hunk.header)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                Spacer()
            }
            .background(Color.blue.opacity(0.06))

            ForEach(hunk.lines) { line in
                DiffLineView(line: line, filePath: filePath)
            }
        }
    }
}

struct DiffLineView: View {
    @Environment(AppState.self) private var appState
    let line: DiffLine
    let filePath: String
    @State private var showCommentPopover = false
    @State private var commentText = ""
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Comment gutter — clickable on the whole row via overlay
            Image(systemName: "plus.bubble.fill")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
                .opacity(isHovering && !showCommentPopover ? 1 : 0)
                .frame(width: 24, height: 18)
                .contentShape(Rectangle())
                .onTapGesture {
                    showCommentPopover = true
                }

            // Old line number
            Text(line.oldLine.map { String($0) } ?? "")
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 4)
                .foregroundStyle(.tertiary)

            // New line number
            Text(line.newLine.map { String($0) } ?? "")
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)
                .foregroundStyle(.tertiary)

            // Marker
            Text(marker)
                .frame(width: 14)
                .foregroundStyle(markerColor)

            // Content
            Text(line.content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.trailing, 8)
        .padding(.vertical, 0.5)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: $showCommentPopover, arrowEdge: .trailing) {
            LineCommentPopover(
                filePath: filePath,
                lineNew: line.newLine,
                lineOld: line.oldLine,
                commentText: $commentText,
                onSubmit: {
                    guard !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    appState.addComment(
                        message: commentText,
                        filePath: filePath,
                        lineNew: line.newLine,
                        lineOld: line.oldLine
                    )
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

    private var marker: String {
        switch line.kind {
        case .context: " "
        case .added: "+"
        case .removed: "-"
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .context: .secondary
        case .added: .green
        case .removed: .red
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .context: .clear
        case .added: .green.opacity(0.08)
        case .removed: .red.opacity(0.08)
        }
    }
}

struct LineCommentPopover: View {
    let filePath: String
    let lineNew: UInt32?
    let lineOld: UInt32?
    @Binding var commentText: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Comment on")
                    .font(.headline)
                Text(locationLabel)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $commentText)
                .font(.system(.body, design: .monospaced))
                .frame(width: 360, height: 80)
                .border(Color(nsColor: .separatorColor))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Comment", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private var locationLabel: String {
        var parts: [String] = [filePath]
        if let n = lineNew { parts.append("L\(n)") }
        return parts.joined(separator: ":")
    }
}
