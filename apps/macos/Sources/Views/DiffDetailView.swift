import SwiftUI

struct DiffDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let file = appState.selectedFile {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DiffFileHeader(file: file)
                    ForEach(file.hunks) { hunk in
                        DiffHunkView(hunk: hunk)
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
            Text("\(addedCount) additions, \(removedCount) deletions")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hunk header
            HStack(spacing: 0) {
                Text(hunk.header)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                Spacer()
            }
            .background(Color.blue.opacity(0.06))

            // Lines
            ForEach(hunk.lines) { line in
                DiffLineView(line: line)
            }
        }
    }
}

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Old line number
            Text(line.oldLine.map { String($0) } ?? "")
                .frame(width: 50, alignment: .trailing)
                .padding(.trailing, 4)
                .foregroundStyle(.tertiary)

            // New line number
            Text(line.newLine.map { String($0) } ?? "")
                .frame(width: 50, alignment: .trailing)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 0.5)
        .background(backgroundColor)
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
