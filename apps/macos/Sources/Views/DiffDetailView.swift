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
      VStack(spacing: 0) {
        if appState.showSearch {
          DiffSearchBar()
        }
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
              // Orphaned threads (file no longer in diff)
              let orphaned = orphanedThreads
              if !orphaned.isEmpty {
                OrphanedThreadsSection(threads: orphaned)
                  .id("__orphaned__")
              }

              ForEach(appState.files) { file in
                Section {
                  let anchored = anchoredItems(for: file)

                  let outdated = outdatedThreads(for: file)
                  if !outdated.isEmpty {
                    OutdatedThreadsSection(threads: outdated)
                  }

                  if appState.diffMode == .unified {
                    ForEach(file.hunks) { hunk in
                      DiffHunkView(hunk: hunk, filePath: file.newPath, anchored: anchored)
                    }
                  } else {
                    SideBySideDiffView(file: file, anchored: anchored)
                  }

                  Color.clear.frame(height: 12)
                } header: {
                  DiffFileHeader(file: file)
                    .id(file.id)
                }
              }
            }
            .padding(.bottom, 20)
            .id(appState.diffMode)
          }
          .onChange(of: appState.scrollToFile) { _, fileId in
            if let fileId {
              proxy.scrollTo(fileId, anchor: .top)
              appState.scrollToFile = nil
            }
          }
          .onChange(of: appState.scrollToSearchMatch) { _, lineId in
            if let lineId {
              withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(lineId, anchor: .center)
              }
              appState.scrollToSearchMatch = nil
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
      }  // VStack
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

  /// Threads whose file is not in the current diff at all.
  private var orphanedThreads: [ReviewThread] {
    guard let session = appState.session else { return [] }
    let filesInDiff = Set(appState.files.map(\.newPath))
    return session.threads.filter { thread in
      guard let anchor = thread.comments.first?.anchor,
        let filePath = anchor.filePath
      else {
        // Global comments (no file) — not orphaned
        return false
      }
      return !filesInDiff.contains(filePath)
    }
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

// MARK: - Search Bar

struct DiffSearchBar: View {
  @Environment(AppState.self) private var appState
  @FocusState private var isFocused: Bool

  var body: some View {
    @Bindable var state = appState

    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)

      TextField("Search in diff...", text: $state.searchQuery)
        .textFieldStyle(.plain)
        .font(.system(.body, design: .monospaced))
        .focused($isFocused)
        .onSubmit {
          appState.navigateToNextMatch()
        }
        .onChange(of: appState.searchQuery) {
          appState.updateSearchMatches()
        }

      if !appState.searchQuery.isEmpty {
        if appState.searchMatches.isEmpty {
          Text("No matches")
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
          Text("\(appState.currentSearchMatchIndex + 1)/\(appState.searchMatches.count)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(minWidth: 40)

          Button {
            appState.navigateToPreviousMatch()
          } label: {
            Image(systemName: "chevron.up")
              .font(.system(size: 10, weight: .semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .keyboardShortcut("g", modifiers: [.command, .shift])

          Button {
            appState.navigateToNextMatch()
          } label: {
            Image(systemName: "chevron.down")
              .font(.system(size: 10, weight: .semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .keyboardShortcut("g", modifiers: .command)
        }

        Button {
          appState.searchQuery = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
      }

      Button {
        appState.toggleSearch()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.escape, modifiers: [])
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
    }
    .onAppear {
      isFocused = true
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
        RollingNumber(file.addedCount, prefix: "+", color: .green)
        RollingNumber(file.removedCount, prefix: "-", color: .red)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }
}

// MARK: - Orphaned Threads (file not in diff)

struct OrphanedThreadsSection: View {
  let threads: [ReviewThread]
  @State private var isExpanded = true

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
          Image(systemName: "archivebox")
            .font(.caption)
          Text(
            "\(threads.count) comment\(threads.count == 1 ? "" : "s") on files not in this diff"
          )
          .font(.caption)
          .fontWeight(.medium)
          Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.06))
      }
      .buttonStyle(.plain)

      if isExpanded {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(threads) { thread in
            VStack(alignment: .leading, spacing: 2) {
              if let anchor = thread.comments.first?.anchor,
                let filePath = anchor.filePath
              {
                HStack(spacing: 4) {
                  Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                  Text(filePath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                  if let line = anchor.lineNew {
                    Text(":\(line)")
                      .font(.system(.caption2, design: .monospaced))
                      .foregroundStyle(.tertiary)
                  }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
              }
              InlineThreadView(thread: thread, isOutdated: true)
            }
          }
        }
        .padding(.bottom, 4)
      }

      Divider()
    }
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

// MARK: - Hunk (Unified Mode)

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
          .id(line.id)

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

// MARK: - Side-by-Side Diff View

struct SideBySideDiffView: View {
  @Environment(AppState.self) private var appState
  let file: FileDiff
  let anchored: [UInt32: [InlineItem]]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if file.sideBySide.isEmpty {
        // Fallback: render unified hunks when side-by-side data is not available
        ForEach(file.hunks) { hunk in
          DiffHunkView(hunk: hunk, filePath: file.newPath, anchored: anchored)
        }
      } else {
        ForEach(file.sideBySide) { pair in
          SideBySideRowView(pair: pair, filePath: file.newPath)

          // Show inline items for the right (new) side line
          if let right = pair.right, let lineNum = right.newLine {
            if appState.activeCommentLineId == right.id {
              InlineCommentEditor(filePath: file.newPath, line: right)
            }
            if let items = anchored[lineNum] {
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
  }
}

struct SideBySideRowView: View {
  @Environment(AppState.self) private var appState
  let pair: SideBySidePair
  let filePath: String
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 0) {
      // Left side (old)
      sideView(line: pair.left, isLeft: true)
      Divider()
      // Right side (new)
      sideView(line: pair.right, isLeft: false)
    }
    .font(.system(.body, design: .monospaced))
    .onHover { hovering in
      isHovering = hovering
    }
  }

  @ViewBuilder
  private func sideView(line: DiffLine?, isLeft: Bool) -> some View {
    if let line {
      HStack(alignment: .top, spacing: 0) {
        if !isLeft {
          commentButton(for: line)
        }

        Text(lineNumber(line, isLeft: isLeft))
          .frame(width: 44, alignment: .trailing)
          .padding(.trailing, 4)
          .foregroundStyle(.tertiary)

        StyledSpansView(spans: line.spans, lineKind: line.kind)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.trailing, 4)
      .padding(.vertical, 0.5)
      .background(sideBackground(line.kind))
      .contentShape(Rectangle())
      .onTapGesture {
        if !isLeft {
          appState.requestCommentEditor(for: line.id)
        }
      }
    } else {
      Color(nsColor: .textBackgroundColor).opacity(0.3)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 20)
    }
  }

  private func commentButton(for line: DiffLine) -> some View {
    let isActive = appState.activeCommentLineId == line.id
    return Image(systemName: "plus.bubble.fill")
      .font(.system(size: 10))
      .foregroundStyle(.blue)
      .opacity(isHovering && !isActive ? 1 : 0)
      .frame(width: 24, height: 18)
  }

  private func lineNumber(_ line: DiffLine, isLeft: Bool) -> String {
    if isLeft {
      return line.oldLine.map { String($0) } ?? ""
    } else {
      return line.newLine.map { String($0) } ?? ""
    }
  }

  private func sideBackground(_ kind: DiffLineKind) -> Color {
    switch kind {
    case .context: .clear
    case .added: .green.opacity(0.08)
    case .removed: .red.opacity(0.08)
    }
  }
}

// MARK: - Styled Spans Rendering

struct StyledSpansView: View {
  @Environment(AppState.self) private var appState
  let spans: [StyledSpan]
  var lineKind: DiffLineKind = .context

  private var hasChangedSpans: Bool {
    spans.contains(where: \.changed)
  }

  private var searchQuery: String {
    appState.searchQuery.lowercased()
  }

  var body: some View {
    if hasChangedSpans || !searchQuery.isEmpty {
      // Use HStack for per-span backgrounds (word changes or search highlights)
      HStack(spacing: 0) {
        ForEach(Array(splitSpansForSearch().enumerated()), id: \.offset) { _, segment in
          Text(segment.text)
            .foregroundColor(spanForeground(segment))
            .bold(segment.bold)
            .italic(segment.italic)
            .background(segmentBackground(segment))
        }
      }
    } else {
      // Fast path: concatenated Text
      spans.reduce(Text("")) { result, span in
        result + styledText(for: span)
      }
    }
  }

  /// Split spans at search match boundaries so each segment is either
  /// a match or not.
  private func splitSpansForSearch() -> [SearchSegment] {
    var result: [SearchSegment] = []
    for span in spans {
      if searchQuery.isEmpty {
        result.append(
          SearchSegment(from: span, isSearchMatch: false))
      } else {
        let text = span.text
        let lower = text.lowercased()
        var pos = lower.startIndex
        while pos < lower.endIndex {
          if let range = lower.range(of: searchQuery, range: pos..<lower.endIndex) {
            // Before match
            if range.lowerBound > pos {
              result.append(
                SearchSegment(
                  text: String(text[pos..<range.lowerBound]), from: span,
                  isSearchMatch: false))
            }
            // Match
            result.append(
              SearchSegment(
                text: String(text[range.lowerBound..<range.upperBound]), from: span,
                isSearchMatch: true))
            pos = range.upperBound
          } else {
            // Rest is not a match
            result.append(
              SearchSegment(
                text: String(text[pos..<lower.endIndex]), from: span, isSearchMatch: false))
            pos = lower.endIndex
          }
        }
      }
    }
    return result
  }

  private func styledText(for span: StyledSpan) -> Text {
    var text = Text(span.text)
    if let fg = span.fg, let color = Color(hex: fg) {
      text = text.foregroundColor(color)
    }
    if span.bold {
      text = text.bold()
    }
    if span.italic {
      text = text.italic()
    }
    return text
  }

  private func spanForeground(_ segment: SearchSegment) -> Color? {
    guard let fg = segment.fg else { return nil }
    return Color(hex: fg)
  }

  private func segmentBackground(_ segment: SearchSegment) -> Color {
    if segment.isSearchMatch {
      return Color.yellow.opacity(0.4)
    }
    if segment.changed {
      return changedBackground
    }
    return .clear
  }

  private var changedBackground: Color {
    switch lineKind {
    case .added: Color.green.opacity(0.2)
    case .removed: Color.red.opacity(0.2)
    case .context: Color.yellow.opacity(0.15)
    }
  }
}

// MARK: - Search Segment

private struct SearchSegment {
  let text: String
  let fg: String?
  let bold: Bool
  let italic: Bool
  let changed: Bool
  let isSearchMatch: Bool

  init(from span: StyledSpan, isSearchMatch: Bool) {
    self.text = span.text
    self.fg = span.fg
    self.bold = span.bold
    self.italic = span.italic
    self.changed = span.changed
    self.isSearchMatch = isSearchMatch
  }

  init(text: String, from span: StyledSpan, isSearchMatch: Bool) {
    self.text = text
    self.fg = span.fg
    self.bold = span.bold
    self.italic = span.italic
    self.changed = span.changed
    self.isSearchMatch = isSearchMatch
  }
}

// MARK: - Color hex extension

extension Color {
  init?(hex: String) {
    var hexStr = hex
    if hexStr.hasPrefix("#") {
      hexStr = String(hexStr.dropFirst())
    }
    guard hexStr.count == 6,
      let val = UInt64(hexStr, radix: 16)
    else { return nil }
    let r = Double((val >> 16) & 0xFF) / 255.0
    let g = Double((val >> 8) & 0xFF) / 255.0
    let b = Double(val & 0xFF) / 255.0
    self.init(red: r, green: g, blue: b)
  }
}

// MARK: - Inline Thread

struct InlineThreadView: View {
  @Environment(AppState.self) private var appState
  let thread: ReviewThread
  let isOutdated: Bool
  @State private var isCollapsed: Bool
  @State private var showReplyEditor = false
  @State private var replyText = ""

  init(thread: ReviewThread, isOutdated: Bool) {
    self.thread = thread
    self.isOutdated = isOutdated
    self._isCollapsed = State(initialValue: isOutdated || thread.state == .resolved)
  }

  private var isSessionActive: Bool {
    guard let session = appState.session else { return false }
    return session.status != .approved && session.status != .closed
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Thread header
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
          // Comments
          ForEach(thread.comments) { comment in
            InlineCommentBubble(comment: comment)
          }

          // Thread actions
          if isSessionActive {
            HStack(spacing: 8) {
              // Reply button
              Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                  showReplyEditor.toggle()
                }
              } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                  .font(.caption)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.blue)

              // Resolve button
              if thread.state != .resolved {
                Button {
                  appState.resolveThread(thread.id.uuidString)
                } label: {
                  Label("Resolve", systemImage: "checkmark.circle")
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
              }

              // Reopen indicator
              if thread.state == .resolved {
                Text("Resolved")
                  .font(.caption)
                  .foregroundStyle(.green)
              }
            }
            .padding(.top, 4)
          }

          // Reply editor
          if showReplyEditor {
            VStack(alignment: .leading, spacing: 6) {
              FocusedTextEditor(
                text: $replyText,
                onCommandReturn: { submitReply() }
              )
              .frame(height: 60)
              .clipShape(RoundedRectangle(cornerRadius: 6))
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
              )

              HStack {
                Text("\u{2318}\u{23CE}")
                  .font(.caption)
                  .fontWeight(.medium)
                  .padding(.horizontal, 4)
                  .padding(.vertical, 1)
                  .background(Color(nsColor: .separatorColor).opacity(0.3))
                  .clipShape(RoundedRectangle(cornerRadius: 3))
                  .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") {
                  showReplyEditor = false
                  replyText = ""
                }
                .controlSize(.small)
                Button("Reply") {
                  submitReply()
                }
                .controlSize(.small)
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              }
            }
            .padding(.top, 4)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
      }
    }
    .background(threadBackground)
  }

  private func submitReply() {
    let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    appState.replyToThread(thread.id.uuidString, message: text)
    replyText = ""
    showReplyEditor = false
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
          submitImmediate()
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
        Text("comment")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer()
        Button("Cancel") {
          appState.closeCommentEditor()
        }
        .controlSize(.small)
        Button("Add to Review") {
          addToDraft()
        }
        .controlSize(.small)
        .disabled(isEmpty)
        Button("Comment") {
          submitImmediate()
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .disabled(isEmpty)
      }
    }
    .padding(12)
    .background(Color.blue.opacity(0.03))
  }

  private func submitImmediate() {
    guard !isEmpty else { return }
    guard let sessionId = appState.sessionId, let repoRoot = appState.repoRoot else { return }
    do {
      try ArgonCLI.addComment(
        sessionId: sessionId, repoRoot: repoRoot,
        message: appState.activeCommentText,
        filePath: filePath,
        lineNew: line.newLine,
        lineOld: line.oldLine
      )
      appState.refreshSession()
    } catch {
      appState.errorMessage = error.localizedDescription
    }
    appState.closeCommentEditor()
  }

  private func addToDraft() {
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

// MARK: - Diff Line (Unified Mode)

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

      if line.spans.count > 1 {
        StyledSpansView(spans: line.spans, lineKind: line.kind)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(line.content)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
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
