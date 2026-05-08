import AppKit
import SwiftUI

struct WorkspaceReviewPreparationSheet: View {
  @State private var preparation: WorkspaceReviewPreparation

  let candidates: [WorkspaceTerminalTab]
  let onChange: (WorkspaceReviewPreparation) -> Void
  let onLaunchAgent: () -> Void
  let onStartReview: (WorkspaceReviewPreparation) -> Void
  let onCancel: () -> Void

  init(
    preparation: WorkspaceReviewPreparation,
    candidates: [WorkspaceTerminalTab],
    onChange: @escaping (WorkspaceReviewPreparation) -> Void,
    onLaunchAgent: @escaping () -> Void,
    onStartReview: @escaping (WorkspaceReviewPreparation) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self._preparation = State(initialValue: preparation)
    self.candidates = candidates
    self.onChange = onChange
    self.onLaunchAgent = onLaunchAgent
    self.onStartReview = onStartReview
    self.onCancel = onCancel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "text.badge.checkmark")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("Choose Coder")
            .font(.title2.weight(.semibold))
          Text("Select the running coder that should receive the review prompt.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 12) {
        if candidates.isEmpty {
          Text("No running coder agents are available in this worktree.")
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            Text("Coder")
              .font(.callout.weight(.medium))
              .foregroundStyle(.secondary)

            Picker("Coder", selection: selectedAgentBinding) {
              Text("Select a coder").tag(UUID?.none)
              ForEach(candidates) { tab in
                Text(tab.title).tag(UUID?.some(tab.id))
              }
            }
            .pickerStyle(.menu)
          }
        }
      }

      HStack {
        Button("New or External Agent…") {
          onChange(preparation.normalized())
          onLaunchAgent()
        }

        Spacer()

        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)

        Button("Open Review") {
          let normalizedPreparation = preparation.normalized()
          onChange(normalizedPreparation)
          onStartReview(normalizedPreparation)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(preparation.selectedAgentTabID == nil)
      }
    }
    .padding(24)
    .frame(width: 520)
  }

  private var selectedAgentBinding: Binding<UUID?> {
    Binding(
      get: { preparation.selectedAgentTabID },
      set: { newValue in
        preparation.selectedAgentTabID = newValue
        onChange(preparation)
      }
    )
  }

}

struct WorkspaceReviewInspectorPane: View {
  let summaryText: String?
  let snapshot: WorkspaceReviewSnapshot?

  var body: some View {
    WorkspaceSurface {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Label("Review", systemImage: "text.magnifyingglass")
            .font(.headline)
          Spacer()
          if let snapshot {
            WorkspaceReviewStatusPill(status: snapshot.status)
          } else {
            WorkspaceStatusPill(label: "draft", tint: .secondary)
          }
        }

        if let snapshot, let outcome = snapshot.decisionOutcome {
          WorkspaceDecisionPill(outcome: outcome)
        }

        if let summaryText, !summaryText.isEmpty {
          Text(summaryText)
            .font(.subheadline)
            .textSelection(.enabled)
            .lineLimit(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let snapshot {
          Text("Updated \(snapshot.updatedAt, style: .relative) ago")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
