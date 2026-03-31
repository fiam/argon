import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    Group {
      if let error = appState.errorMessage, appState.session == nil {
        EmptyStateView(
          icon: "exclamationmark.triangle",
          title: "Something went wrong",
          detail: error
        )
      } else if let session = appState.session {
        ReviewLayout(session: session)
      } else if appState.isLoading {
        ProgressView("Loading session...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        EmptyStateView(
          icon: "arrow.right.circle",
          title: "No session",
          detail: "Launch from the terminal: argon . (in a git repo)"
        )
      }
    }
    .onAppear {
      appState.loadSession()
      appState.startPolling()
    }
    .onDisappear {
      let isTerminal =
        appState.session.map {
          $0.status == .approved || $0.status == .closed
        } ?? true
      if !isTerminal {
        appState.closeSession()
      } else {
        appState.stopPolling()
      }
    }
    .navigationTitle(windowTitle)
  }

  private var windowTitle: String {
    guard let session = appState.session else { return "Argon" }
    let repo = URL(fileURLWithPath: session.repoRoot).lastPathComponent
    return "Argon \u{2014} \(repo)"
  }
}

struct ReviewLayout: View {
  @Environment(AppState.self) private var appState
  let session: ReviewSession
  @State private var showInspector = true

  var body: some View {
    NavigationSplitView {
      FileTreeSidebar()
        .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 300)
    } detail: {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          SessionHeader(session: session, fileCount: appState.files.count)
          if appState.isLoading {
            ProgressView()
              .controlSize(.small)
              .padding(.trailing, 8)
          }
        }
        Divider()

        if appState.showAgentTerminals && !appState.reviewerAgents.isEmpty {
          VSplitView {
            DiffDetailView()
              .frame(minHeight: 200)
            ReviewerAgentTabsView()
              .frame(minHeight: 150, idealHeight: 250)
          }
        } else {
          DiffDetailView()
        }
      }
      .inspector(isPresented: $showInspector) {
        ThreadsSidebar(session: session)
          .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        if !appState.reviewerAgents.isEmpty {
          Button {
            appState.showAgentTerminals.toggle()
          } label: {
            Image(systemName: "terminal")
          }
          .help(
            appState.showAgentTerminals ? "Hide agent terminals" : "Show agent terminals"
          )
        }

        Button {
          showInspector.toggle()
        } label: {
          Image(systemName: "sidebar.trailing")
        }
        .help(showInspector ? "Hide comments" : "Show comments")
      }
    }
  }
}

// MARK: - File Tree Sidebar

struct FileTreeSidebar: View {
  @Environment(AppState.self) private var appState
  @State private var filterText = ""
  @State private var showModeHelp = false

  private var currentMode: FilterMode {
    detectFilterMode(filterText)
  }

  private var filteredFiles: [FileDiff] {
    filterFiles(appState.files, pattern: filterText)
  }

  private var treeNodes: [FileTreeNode] {
    buildFileTree(from: filteredFiles)
  }

  @FocusState private var filterFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Filter field
      VStack(spacing: 0) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 11))
            .foregroundStyle(filterText.isEmpty ? .quaternary : .secondary)

          TextField("Filter files", text: $filterText)
            .textFieldStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .focused($filterFocused)

          if !filterText.isEmpty {
            Button {
              showModeHelp = true
            } label: {
              Text(currentMode.label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(currentMode.color.opacity(0.15))
                .foregroundStyle(currentMode.color)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showModeHelp, arrowEdge: .bottom) {
              VStack(alignment: .leading, spacing: 6) {
                Text(currentMode.help)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(12)
              .frame(width: 280)
            }

            Text("\(filteredFiles.count)/\(appState.files.count)")
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.tertiary)

            Button {
              filterText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)

        if filterText.isEmpty {
          HStack(spacing: 3) {
            Text("fuzzy")
              .foregroundStyle(.quaternary)
            Text("·")
              .foregroundStyle(.quaternary)
            Text("*?")
              .font(.system(.caption2, design: .monospaced))
              .fontWeight(.medium)
              .foregroundStyle(.quaternary)
            Text("glob")
              .foregroundStyle(.quaternary)
            Text("·")
              .foregroundStyle(.quaternary)
            Text("/")
              .font(.system(.caption2, design: .monospaced))
              .fontWeight(.medium)
              .foregroundStyle(.quaternary)
            Text("regex")
              .foregroundStyle(.quaternary)
          }
          .font(.system(size: 9))
          .padding(.bottom, 4)
        }
      }
      .background(Color(nsColor: .textBackgroundColor))
      .onChange(of: appState.focusFileFilter) { _, focused in
        if focused {
          filterFocused = true
          appState.focusFileFilter = false
        }
      }
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(height: 0.5)
      }

      // Tree
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(treeNodes) { node in
            FileTreeNodeView(node: node, depth: 0)
          }
        }
        .padding(.vertical, 2)
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
  }
}

struct FileTreeNodeView: View {
  @Environment(AppState.self) private var appState
  @Bindable var node: FileTreeNode
  let depth: Int

  var body: some View {
    if node.isDirectory {
      // Directory row
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          node.isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .frame(width: 12)
            .foregroundStyle(.tertiary)
          Image(systemName: node.isExpanded ? "folder.fill" : "folder")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(node.name)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer()
          Text("\(node.fileCount)")
            .font(.caption2)
            .foregroundStyle(.quaternary)
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if node.isExpanded {
        ForEach(node.children) { child in
          FileTreeNodeView(node: child, depth: depth + 1)
        }
      }
    } else if let file = node.file {
      // File row
      FileTreeFileRow(file: file, name: node.name, depth: depth)
    }
  }
}

struct FileTreeFileRow: View {
  @Environment(AppState.self) private var appState
  let file: FileDiff
  let name: String
  let depth: Int

  private var isSelected: Bool {
    appState.selectedFile?.id == file.id
  }

  var body: some View {
    Button {
      appState.selectedFile = file
      appState.scrollToFile = file.id
    } label: {
      HStack(spacing: 4) {
        Spacer().frame(width: 12)  // align with chevron
        Image(systemName: fileIcon)
          .font(.caption)
          .foregroundStyle(fileIconColor)
        Text(name)
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1)
        Spacer()
        HStack(spacing: 2) {
          if file.addedCount > 0 {
            RollingNumber(
              file.addedCount, prefix: "+", color: Color(nsColor: .systemGreen), font: .caption2)
          }
          if file.removedCount > 0 {
            RollingNumber(
              file.removedCount, prefix: "-", color: Color(nsColor: .systemRed), font: .caption2)
          }
        }
      }
      .padding(.leading, CGFloat(depth) * 14 + 6)
      .padding(.trailing, 10)
      .padding(.vertical, 3)
      .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var fileIcon: String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "rs": return "gearshape.2"
    case "toml", "yml", "yaml", "json": return "doc.text"
    case "md": return "doc.richtext"
    case "sh": return "terminal"
    case "go": return "chevron.left.forwardslash.chevron.right"
    case "py": return "text.word.spacing"
    case "js", "ts", "jsx", "tsx": return "curlybraces"
    default: return "doc"
    }
  }

  private var fileIconColor: Color {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return .orange
    case "rs": return .brown
    case "go": return .cyan
    case "py": return .blue
    case "js", "jsx": return .yellow
    case "ts", "tsx": return .blue
    case "md": return .purple
    default: return .secondary
    }
  }
}

// MARK: - Threads Sidebar

enum ThreadFilter: String, CaseIterable {
  case all = "All"
  case open = "Open"
  case resolved = "Resolved"
}

struct ThreadsSidebar: View {
  @Environment(AppState.self) private var appState
  let session: ReviewSession
  @State private var showCommentPopover = false
  @State private var commentText = ""
  @State private var threadFilter: ThreadFilter = .all

  private var filteredThreads: [ReviewThread] {
    switch threadFilter {
    case .all: session.threads
    case .open: session.threads.filter { $0.state == .open || $0.state == .addressed }
    case .resolved: session.threads.filter { $0.state == .resolved }
    }
  }

  private var openCount: Int {
    session.threads.filter { $0.state == .open || $0.state == .addressed }.count
  }

  var body: some View {
    VStack(spacing: 0) {
      // Summary bar
      if !session.threads.isEmpty {
        HStack(spacing: 6) {
          ForEach(ThreadFilter.allCases, id: \.self) { filter in
            Button {
              threadFilter = filter
            } label: {
              Text(filterLabel(filter))
                .font(.caption2)
                .fontWeight(threadFilter == filter ? .medium : .regular)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(threadFilter == filter ? Color.accentColor.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .foregroundStyle(threadFilter == filter ? .primary : .secondary)
          }
          Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        Divider()
      }

      // Add comment
      if session.status != .approved && session.status != .closed {
        Button {
          showCommentPopover = true
        } label: {
          Label("Add Comment", systemImage: "plus.bubble")
            .font(.caption)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
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
        Divider()
      }

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          // Pending drafts
          if !appState.pendingDrafts.isEmpty {
            Text("Pending Review")
              .font(.caption2)
              .fontWeight(.medium)
              .foregroundStyle(.purple)
            ForEach(appState.pendingDrafts) { draft in
              DraftRow(draft: draft)
            }
            if !filteredThreads.isEmpty { Divider() }
          }

          // Agent decisions summary
          let agentDecisions = reviewerAgentDecisions
          if !agentDecisions.isEmpty {
            ForEach(agentDecisions, id: \.name) { decision in
              HStack(spacing: 4) {
                Image(systemName: decision.icon)
                  .font(.caption2)
                  .foregroundStyle(decision.color)
                Text(decision.name)
                  .font(.caption2)
                  .fontWeight(.medium)
                  .foregroundStyle(colorFromName(decision.name))
                Text(decision.outcome)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              .padding(.vertical, 2)
            }
            if !filteredThreads.isEmpty { Divider() }
          }

          // Threads
          ForEach(filteredThreads) { thread in
            Button {
              scrollToThread(thread)
            } label: {
              SidebarThreadRow(thread: thread)
            }
            .buttonStyle(.plain)
          }

          if appState.pendingDrafts.isEmpty && session.threads.isEmpty {
            Text("No comments yet")
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity)
              .padding(.top, 20)
          }
        }
        .padding(8)
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
  }

  private func filterLabel(_ filter: ThreadFilter) -> String {
    switch filter {
    case .all: "All (\(session.threads.count))"
    case .open: "Open (\(openCount))"
    case .resolved: "Resolved (\(session.threads.count - openCount))"
    }
  }

  private func scrollToThread(_ thread: ReviewThread) {
    appState.scrollToThread = thread.id.uuidString
  }

  private struct AgentDecisionInfo {
    let name: String
    let outcome: String
    let icon: String
    let color: Color
  }

  /// Collect decisions from named reviewer agents.
  private var reviewerAgentDecisions: [AgentDecisionInfo] {
    guard let decision = session.decision else { return [] }
    // Check if any running agents match
    var results: [AgentDecisionInfo] = []
    for agent in appState.reviewerAgents {
      let (icon, color, label): (String, Color, String) =
        switch decision.outcome {
        case .changesRequested: ("arrow.uturn.backward.circle.fill", .orange, "changes requested")
        case .commented: ("text.bubble.fill", .blue, "commented")
        case .approved: ("checkmark.circle.fill", .green, "approved")
        }
      results.append(
        AgentDecisionInfo(name: agent.nickname, outcome: label, icon: icon, color: color))
    }
    return results
  }
}

// MARK: - Sidebar Rows

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
    .padding(6)
    .background(Color.purple.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}

struct SidebarThreadRow: View {
  let thread: ReviewThread

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        threadStateBadge
        if let anchor = thread.comments.first?.anchor,
          let file = anchor.filePath
        {
          Text(URL(fileURLWithPath: file).lastPathComponent)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if let line = anchor.lineNew {
            Text(":\(line)")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
        Spacer()
        Text("\(thread.comments.count)")
          .font(.caption2)
          .foregroundStyle(.quaternary)
      }
      // Show only first and last comment for brevity
      if let first = thread.comments.first {
        sidebarCommentRow(first)
      }
      if thread.comments.count > 2 {
        Text("···  \(thread.comments.count - 2) more")
          .font(.caption2)
          .foregroundStyle(.quaternary)
      }
      if thread.comments.count > 1, let last = thread.comments.last {
        sidebarCommentRow(last)
      }
    }
    .padding(6)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  private func sidebarCommentRow(_ comment: ReviewComment) -> some View {
    HStack(alignment: .top, spacing: 4) {
      Text(commentAuthorLabel(comment))
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundStyle(authorColor(comment))
      Text(comment.body)
        .font(.caption2)
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }
  }

  private func authorColor(_ comment: ReviewComment) -> Color {
    if comment.author == .agent { return .cyan }
    if let name = comment.authorName { return colorFromName(name) }
    return .blue  // human
  }

  @ViewBuilder
  private var threadStateBadge: some View {
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

  private func commentAuthorLabel(_ comment: ReviewComment) -> String {
    if let name = comment.authorName { return name }
    return comment.author == .reviewer ? "reviewer" : "agent"
  }
}

// MARK: - Empty State

struct EmptyStateView: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 40))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.title2)
        .fontWeight(.medium)
      Text(detail)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
