import SwiftUI

struct DiffDetailView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    if appState.files.isEmpty && !appState.isLoading {
      EmptyStateView(
        icon: "checkmark.circle",
        title: "No changes",
        detail: "No differences found for the current review mode."
      )
    } else if appState.files.isEmpty {
      Color.clear
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(appState.files) { file in
              Section {
                let anchored = anchoredItems(for: file)

                let outdated = outdatedThreads(for: file)
                if !outdated.isEmpty {
                  OutdatedThreadsSection(threads: outdated)
                }

                ForEach(file.hunks) { hunk in
                  DiffHunkView(hunk: hunk, filePath: file.newPath, anchored: anchored)
                }

                Color.clear.frame(height: 12)
              } header: {
                DiffFileHeader(file: file)
                  .id(file.id)
              }
            }
          }
          .padding(.bottom, 20)
        }
        .onChange(of: appState.scrollToFile) { _, fileId in
          if let fileId {
            withAnimation {
              proxy.scrollTo(fileId, anchor: .top)
            }
            appState.scrollToFile = nil
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .textBackgroundColor))
      .alert(
        "Discard comment?",
        isPresented: Binding(
          get: { appState.showDiscardAlert },
          set: { appState.showDiscardAlert = $0 }
        )
      ) {
        Button("Discard", role: .destructive) {
          appState.confirmDiscard()
        }
        Button("Keep Editing", role: .cancel) {
          appState.cancelDiscard()
        }
      } message: {
        Text("You have an unsaved comment. Discard it and start a new one?")
      }
    }
  }

  private func anchoredItems(for file: FileDiff) -> [UInt32: [InlineItem]] {
    var result: [UInt32: [InlineItem]] = [:]

    if let session = appState.session {
      for thread in session.threads {
        guard let anchor = thread.comments.first?.anchor,
          anchor.filePath == file.newPath,
          let line = anchor.lineNew
        else { continue }
        result[line, default: []].append(.thread(thread))
      }
    }

    for draft in appState.pendingDrafts {
      guard draft.anchor.filePath == file.newPath,
        let line = draft.anchor.lineNew
      else { continue }
      result[line, default: []].append(.draft(draft))
    }

    return result
  }

  private func outdatedThreads(for file: FileDiff) -> [ReviewThread] {
    guard let session = appState.session else { return [] }
    let linesInDiff = Set(file.hunks.flatMap(\.lines).compactMap(\.newLine))

    return session.threads.filter { thread in
      guard let anchor = thread.comments.first?.anchor,
        anchor.filePath == file.newPath
      else { return false }
      guard let line = anchor.lineNew else { return true }
      return !linesInDiff.contains(line)
    }
  }
}

enum InlineItem: Identifiable {
  case thread(ReviewThread)
  case draft(DraftComment)

  var id: String {
    switch self {
    case .thread(let t): "t-\(t.id)"
    case .draft(let d): "d-\(d.id)"
    }
  }
}

// MARK: - File Header (sticky)

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
      HStack(spacing: 4) {
        Text("+\(addedCount)")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.green)
        Text("-\(removedCount)")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.red)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var addedCount: Int {
    file.hunks.flatMap(\.lines).filter { $0.kind == .added }.count
  }

  private var removedCount: Int {
    file.hunks.flatMap(\.lines).filter { $0.kind == .removed }.count
  }
}

// MARK: - Outdated Threads

struct OutdatedThreadsSection: View {
  let threads: [ReviewThread]
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
          Text("\(threads.count) outdated comment\(threads.count == 1 ? "" : "s")")
            .font(.caption)
            .fontWeight(.medium)
          Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.06))
      }
      .buttonStyle(.plain)

      if isExpanded {
        ForEach(threads) { thread in
          InlineThreadView(thread: thread, isOutdated: true)
        }
      }
    }
  }
}

// MARK: - Hunk

struct DiffHunkView: View {
  @Environment(AppState.self) private var appState
  let hunk: DiffHunk
  let filePath: String
  let anchored: [UInt32: [InlineItem]]

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

        // Inline comment editor
        if appState.activeCommentLineId == line.id {
          InlineCommentEditor(filePath: filePath, line: line)
        }

        if let lineNum = line.newLine, let items = anchored[lineNum] {
          ForEach(items) { item in
            switch item {
            case .thread(let thread):
              InlineThreadView(thread: thread, isOutdated: false)
            case .draft(let draft):
              InlineDraftView(draft: draft)
            }
          }
        }
      }
    }
  }
}

// MARK: - Inline Thread

struct InlineThreadView: View {
  let thread: ReviewThread
  let isOutdated: Bool
  @State private var isCollapsed: Bool

  init(thread: ReviewThread, isOutdated: Bool) {
    self.thread = thread
    self.isOutdated = isOutdated
    self._isCollapsed = State(initialValue: isOutdated || thread.state == .resolved)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          isCollapsed.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.caption2)
          threadBadge
          if isOutdated {
            Text("outdated")
              .font(.system(size: 9, weight: .medium))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color.yellow.opacity(0.15))
              .foregroundStyle(.yellow)
              .clipShape(Capsule())
          }
          if let first = thread.comments.first {
            Text(first.body)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          Text("\(thread.comments.count)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
      }
      .buttonStyle(.plain)

      if !isCollapsed {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(thread.comments) { comment in
            InlineCommentBubble(comment: comment)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
      }
    }
    .background(threadBackground)
  }

  @ViewBuilder
  private var threadBadge: some View {
    let (label, color): (String, Color) =
      switch thread.state {
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

  private var threadBackground: Color {
    if isOutdated { return Color.yellow.opacity(0.03) }
    switch thread.state {
    case .open: return Color.orange.opacity(0.04)
    case .addressed: return Color.blue.opacity(0.03)
    case .resolved: return Color.green.opacity(0.03)
    }
  }
}

struct InlineCommentBubble: View {
  let comment: ReviewComment

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: comment.author == .reviewer ? "person.circle.fill" : "cpu")
        .foregroundStyle(comment.author == .reviewer ? .orange : .blue)
        .font(.callout)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(authorLabel)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(comment.author == .reviewer ? .orange : .blue)
          Text(timeAgo(comment.createdAt))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Text(comment.body)
          .font(.callout)
          .textSelection(.enabled)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var authorLabel: String {
    if let name = comment.authorName { return name }
    return comment.author == .reviewer ? "Reviewer" : "Agent"
  }

  private func timeAgo(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    return "\(Int(interval / 86400))d ago"
  }
}

// MARK: - Inline Draft

struct InlineDraftView: View {
  @Environment(AppState.self) private var appState
  let draft: DraftComment

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "pencil.circle.fill")
        .foregroundStyle(.purple)
        .font(.callout)

      VStack(alignment: .leading, spacing: 2) {
        Text("Pending")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.purple)
        Text(draft.body)
          .font(.callout)
          .textSelection(.enabled)
      }

      Spacer()

      Button {
        appState.deleteDraft(draft.id.uuidString)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.purple.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .padding(.horizontal, 16)
    .padding(.vertical, 4)
  }
}

// MARK: - Inline Comment Editor

struct InlineCommentEditor: View {
  @Environment(AppState.self) private var appState
  let filePath: String
  let line: DiffLine

  private var isEmpty: Bool {
    appState.activeCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var title: String {
    var parts = [filePath]
    if let n = line.newLine { parts.append("L\(n)") }
    return parts.joined(separator: ":")
  }

  var body: some View {
    @Bindable var state = appState

    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "text.bubble.fill")
          .foregroundStyle(.blue)
        Text(title)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }

      FocusedTextEditor(
        text: $state.activeCommentText,
        onCommandReturn: {
          submitIfNotEmpty()
        }
      )
      .frame(height: 70)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )

      HStack(spacing: 4) {
        Text("\u{2318}\u{23CE}")
          .font(.caption)
          .fontWeight(.medium)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(Color(nsColor: .separatorColor).opacity(0.3))
          .clipShape(RoundedRectangle(cornerRadius: 3))
        Text("to submit")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer()
        Button("Cancel") {
          appState.closeCommentEditor()
        }
        .controlSize(.small)
        Button("Add Comment") {
          submitIfNotEmpty()
        }
        .controlSize(.small)
        .disabled(isEmpty)
      }
    }
    .padding(12)
    .background(Color.blue.opacity(0.03))
  }

  private func submitIfNotEmpty() {
    guard !isEmpty else { return }
    appState.addDraft(
      message: appState.activeCommentText,
      filePath: filePath,
      lineNew: line.newLine,
      lineOld: line.oldLine
    )
    appState.closeCommentEditor()
  }
}

// MARK: - Diff Line

struct DiffLineView: View {
  @Environment(AppState.self) private var appState
  let line: DiffLine
  let filePath: String
  @State private var isHovering = false

  private var isActive: Bool {
    appState.activeCommentLineId == line.id
  }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      Image(systemName: "plus.bubble.fill")
        .font(.system(size: 10))
        .foregroundStyle(.blue)
        .opacity(isHovering && !isActive ? 1 : 0)
        .frame(width: 24, height: 18)

      Text(line.oldLine.map { String($0) } ?? "")
        .frame(width: 44, alignment: .trailing)
        .padding(.trailing, 4)
        .foregroundStyle(.tertiary)

      Text(line.newLine.map { String($0) } ?? "")
        .frame(width: 44, alignment: .trailing)
        .padding(.trailing, 8)
        .foregroundStyle(.tertiary)

      Text(marker)
        .frame(width: 14)
        .foregroundStyle(markerColor)

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
    .onTapGesture {
      appState.requestCommentEditor(for: line.id)
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

  private var lineCommentTitle: String {
    var parts = [filePath]
    if let n = line.newLine { parts.append("L\(n)") }
    return parts.joined(separator: ":")
  }
}
