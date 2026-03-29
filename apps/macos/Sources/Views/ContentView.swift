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

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 1) {
        ForEach(appState.files) { file in
          FileTreeRow(file: file)
        }
      }
      .padding(.vertical, 4)
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
  }
}

struct FileTreeRow: View {
  @Environment(AppState.self) private var appState
  let file: FileDiff

  private var isSelected: Bool {
    appState.selectedFile?.id == file.id
  }

  var body: some View {
    Button {
      appState.selectedFile = file
      appState.scrollToFile = file.id
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "doc.text")
          .foregroundStyle(.secondary)
          .font(.caption)
        Text(file.displayPath)
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
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
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
