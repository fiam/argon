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
      UITestAutomationSignal.write(
        "content-appeared",
        to: UITestAutomationConfig.current().signalFilePath
      )
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
        .navigationSplitViewColumnWidth(min: 150, ideal: 210, max: 280)
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
        .zIndex(1)
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
      .accessibilityIdentifier("review-layout")
      .inspector(isPresented: $showInspector) {
        ThreadsSidebar(session: session)
          .inspectorColumnWidth(min: 180, ideal: 240, max: 320)
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

  var body: some View {
    FileTreePanel(
      files: appState.files,
      emptyTitle: "No Changed Files",
      emptySystemImage: "doc",
      emptyDescription: "This review has no changed files.",
      selectedFileID: appState.selectedFile?.id,
      focusFilterRequest: appState.focusFileFilter,
      onConsumeFocusFilterRequest: {
        appState.focusFileFilter = false
      },
      onSelectFile: { file in
        appState.navigateToFile(file)
      },
      onOpenFile: nil
    )
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
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
    if let anchor = thread.comments.first?.anchor,
      let filePath = anchor.filePath
    {
      if let file = appState.selectFile(matching: filePath) {
        appState.requestDiffNavigation(
          to: .thread(thread.id),
          fallbackFileID: file.id,
          alignment: .center
        )
      } else {
        appState.requestDiffNavigation(to: .thread(thread.id), alignment: .center)
      }
    } else {
      appState.requestDiffNavigation(to: .thread(thread.id), alignment: .center)
    }
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
  @AppStorage(CommentFontSettings.storageKey)
  private var commentFontSize = CommentFontSettings.defaultSize
  let draft: DraftComment

  private var bodyTextSize: CGFloat {
    CGFloat(CommentFontSettings.clamped(commentFontSize))
  }

  private var metaTextSize: CGFloat {
    max(bodyTextSize - 2, 10)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 4) {
      VStack(alignment: .leading, spacing: 2) {
        if let file = draft.anchor.filePath {
          HStack(spacing: 2) {
            Text(file)
              .font(.system(size: metaTextSize))
              .foregroundStyle(.secondary)
            if let line = draft.anchor.lineNew ?? draft.anchor.lineOld {
              Text(":\(line)")
                .font(.system(size: metaTextSize))
                .foregroundStyle(.secondary)
            }
          }
        }
        Text(draft.body)
          .font(.system(size: bodyTextSize))
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
  @AppStorage(CommentFontSettings.storageKey)
  private var commentFontSize = CommentFontSettings.defaultSize
  let thread: ReviewThread

  private var bodyTextSize: CGFloat {
    CGFloat(CommentFontSettings.clamped(commentFontSize))
  }

  private var metaTextSize: CGFloat {
    max(bodyTextSize - 2, 10)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        threadStateBadge
        if let anchor = thread.comments.first?.anchor,
          let file = anchor.filePath
        {
          Text(URL(fileURLWithPath: file).lastPathComponent)
            .font(.system(size: metaTextSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if let line = anchor.lineNew ?? anchor.lineOld {
            Text(":\(line)")
              .font(.system(size: metaTextSize))
              .foregroundStyle(.tertiary)
          }
        }
        Spacer()
        Text("\(thread.comments.count)")
          .font(.system(size: metaTextSize))
          .foregroundStyle(.quaternary)
      }
      // Show only first and last comment for brevity
      if let first = thread.comments.first {
        sidebarCommentRow(first)
      }
      if thread.comments.count > 2 {
        Text("···  \(thread.comments.count - 2) more")
          .font(.system(size: metaTextSize))
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
        .font(.system(size: metaTextSize, weight: .medium))
        .foregroundStyle(authorColor(comment))
      Text(comment.body)
        .font(.system(size: bodyTextSize))
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
