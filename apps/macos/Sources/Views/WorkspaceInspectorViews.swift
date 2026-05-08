import AppKit
import SwiftUI

struct WorkspaceInspectorPane: View {
  @Environment(WorkspaceState.self) private var workspaceState

  var body: some View {
    GeometryReader { proxy in
      Group {
        if let worktree = workspaceState.selectedWorktree {
          VStack(alignment: .leading, spacing: 14) {
            WorkspaceSurface {
              VStack(alignment: .leading, spacing: 12) {
                WorkspaceDiffModePicker()

                WorkspaceCompactDiffSummary(summary: workspaceState.selectedSummary)

                if workspaceState.hasConflicts(for: worktree.path) {
                  WorkspaceStatusPill(label: "conflicts", tint: .orange)
                }

                WorkspaceEditorLauncher(worktreePath: worktree.path)
                  .frame(maxWidth: .infinity)
                  .layoutPriority(1)
              }
            }
            .fixedSize(horizontal: false, vertical: true)

            if workspaceState.selectedReviewSnapshot != nil
              || workspaceState.selectedReviewSummaryText != nil
            {
              WorkspaceReviewInspectorPane(
                summaryText: workspaceState.selectedReviewSummaryText,
                snapshot: workspaceState.selectedReviewSnapshot
              )
              .frame(maxWidth: .infinity)
            }

            if let selectedTerminalTab = workspaceState.selectedTerminalTab,
              selectedTerminalTab.isSandboxed
            {
              WorkspaceSandboxNetworkPane(tab: selectedTerminalTab)
                .frame(maxWidth: .infinity)
            }

            WorkspaceChangedFilesPane()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .padding(16)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          ContentUnavailableView(
            "No Selection",
            systemImage: "sidebar.right",
            description: Text("Select a worktree to view details and launch review.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(width: 0.5)
    }
  }
}

struct WorkspaceSandboxNetworkPane: View {
  let tab: WorkspaceTerminalTab

  @State private var events: [SandboxNetworkActivityEvent] = []
  @State private var statusSummary: SandboxNetworkStatusSummary?
  @State private var lastVisibleEventID: String?

  var body: some View {
    WorkspaceSurface {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Label("Network", systemImage: "network")
            .font(.headline)
          Spacer()
          Text(tab.title)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if events.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text(statusSummary?.headline ?? "No network activity yet.")
              .font(.subheadline.weight(.medium))
            if let detail = statusSummary?.detail, !detail.isEmpty {
              Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                  WorkspaceSandboxNetworkRow(event: event)
                    .id(event.id)
                  if index < events.count - 1 {
                    Divider()
                      .padding(.vertical, 10)
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
              scrollToNewestEvent(with: proxy, animated: false)
            }
            .onChange(of: events.map(\.id)) { _, _ in
              scrollToNewestEvent(with: proxy, animated: true)
            }
          }
          .frame(minHeight: 96, maxHeight: 220)
        }
      }
    }
    .task(id: tab.id) {
      statusSummary = nil
      events = []
      lastVisibleEventID = nil
      await loadNetworkStatus(for: tab)
      await refreshLoop(for: tab.id)
    }
  }

  private func loadNetworkStatus(for tab: WorkspaceTerminalTab) async {
    let repoRoot = tab.worktreePath
    let processExecutable = tab.launch.processSpec.executable
    let processArguments = tab.launch.processSpec.args
    let summary = await Task.detached(priority: .userInitiated) {
      try? SandboxNetworkStatusLoader.load(
        repoRoot: repoRoot,
        processExecutable: processExecutable,
        processArguments: processArguments
      )
    }.value
    guard !Task.isCancelled else { return }
    statusSummary = summary
  }

  private func refreshLoop(for tabID: UUID) async {
    while !Task.isCancelled {
      let updatedEvents = SandboxNetworkActivityLogStore.loadEvents(for: tabID)
      if updatedEvents != events {
        withAnimation(.easeInOut(duration: 0.2)) {
          events = updatedEvents
        }
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private func scrollToNewestEvent(
    with proxy: ScrollViewProxy,
    animated: Bool
  ) {
    guard let newestEventID = events.last?.id, newestEventID != lastVisibleEventID else { return }
    lastVisibleEventID = newestEventID
    let action = {
      proxy.scrollTo(newestEventID, anchor: .bottom)
    }
    if animated {
      withAnimation(.easeInOut(duration: 0.2), action)
    } else {
      action()
    }
  }
}

struct WorkspaceSandboxNetworkRow: View {
  let event: SandboxNetworkActivityEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(event.title)
          .font(.subheadline.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        Text(event.occurredAt, style: .time)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if let path = event.path, !path.isEmpty {
        Text(path)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      } else if let detail = event.detail, !detail.isEmpty {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      HStack(spacing: 10) {
        Text(event.statusLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(event.outcome == "denied" ? .orange : .secondary)
        Text(event.transferLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct WorkspaceAgentPickerSheet: View {
  let title: String
  let subtitle: String
  let candidates: [WorkspaceTerminalTab]
  let onSelect: (UUID) -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "person.crop.circle.badge.questionmark")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.title2.weight(.semibold))
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        ForEach(candidates) { tab in
          Button {
            onSelect(tab.id)
          } label: {
            HStack(spacing: 12) {
              AgentIconView(icon: tab.kind.iconName, size: 18)
                .frame(width: 22, height: 22)
              VStack(alignment: .leading, spacing: 3) {
                Text(tab.title)
                  .font(.headline)
                Text(tab.commandDescription)
                  .font(.callout.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
          }
          .buttonStyle(.plain)
        }
      }

      HStack {
        Spacer()

        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}
