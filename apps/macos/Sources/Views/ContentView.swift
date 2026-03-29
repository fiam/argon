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
        DiffDetailView()
      }
      .inspector(isPresented: $showInspector) {
        ThreadsSidebar(session: session)
          .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
      }
    }
    .toolbar {
      ToolbarItem(placement: .automatic) {
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

  private var filteredFiles: [FileDiff] {
    filterFiles(appState.files, pattern: filterText)
  }

  private var treeNodes: [FileTreeNode] {
    buildFileTree(from: filteredFiles)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Filter field
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.caption)
          .foregroundStyle(.tertiary)
        TextField("Filter files...", text: $filterText)
          .textFieldStyle(.plain)
          .font(.system(.caption, design: .monospaced))
        if !filterText.isEmpty {
          Button {
            filterText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color(nsColor: .textBackgroundColor))

      Divider()

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
            RollingNumber(file.addedCount, prefix: "+", color: .green, font: .caption2)
          }
          if file.removedCount > 0 {
            RollingNumber(file.removedCount, prefix: "-", color: .red, font: .caption2)
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

struct ThreadsSidebar: View {
  @Environment(AppState.self) private var appState
  let session: ReviewSession
  @State private var showCommentPopover = false
  @State private var commentText = ""

  var body: some View {
    VStack(spacing: 0) {
      if session.status != .approved && session.status != .closed {
        Button {
          showCommentPopover = true
        } label: {
          Label("Add Comment", systemImage: "plus.bubble")
            .font(.callout)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(10)
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
        LazyVStack(alignment: .leading, spacing: 8) {
          if !appState.pendingDrafts.isEmpty {
            Text("Pending Review")
              .font(.caption)
              .fontWeight(.medium)
              .foregroundStyle(.purple)
            ForEach(appState.pendingDrafts) { draft in
              DraftRow(draft: draft)
            }
            if !session.threads.isEmpty {
              Divider()
            }
          }

          if !session.threads.isEmpty {
            Text("Threads")
              .font(.caption)
              .fontWeight(.medium)
              .foregroundStyle(.secondary)
            ForEach(session.threads) { thread in
              SidebarThreadRow(thread: thread)
            }
          }

          if appState.pendingDrafts.isEmpty && session.threads.isEmpty {
            Text("No comments yet")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity)
              .padding(.top, 20)
          }
        }
        .padding(10)
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
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
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        threadStateBadge
        if let anchor = thread.comments.first?.anchor,
          let file = anchor.filePath
        {
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
