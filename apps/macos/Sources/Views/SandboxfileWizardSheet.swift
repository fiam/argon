import AppKit
import SwiftUI

struct SandboxfileWizardSheet: View {
  let request: SandboxfilePromptRequest
  let onCancel: () -> Void
  let onCreate: (SandboxfileWizardConfiguration) -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var configuration = SandboxfileWizardConfiguration.recommended
  @State private var policyColumnHeight: CGFloat = 330

  private static let maxVisibleBuiltinRows: CGFloat = 2.5

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 10) {
        Image(systemName: "shield.lefthalf.filled")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("Create Sandboxfile")
            .font(.title2.weight(.semibold))
          Text(request.launchKind.displayName.capitalized)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      Text(
        "This project does not have a Sandboxfile yet. Argon needs one before launching sandboxed agents or shells. The Sandboxfile limits what agents can read, write, run, and reach on the network so they can run more securely with a project-scoped policy."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack(alignment: .top, spacing: 20) {
        VStack(alignment: .leading, spacing: 16) {
          policyPickers
          repositoryAccess
          builtins
          localOverrides
        }
        .frame(width: 300, alignment: .topLeading)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: SandboxfileWizardPolicyColumnHeightKey.self,
              value: proxy.size.height
            )
          }
        )

        VStack(alignment: .leading, spacing: 0) {
          HighlightedCodeTextView(
            text: previewText,
            path: SandboxfileHelpContent.highlightPath,
            fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            theme: highlightTheme,
            isEditable: false,
            accessibilityIdentifier: "sandboxfile-wizard-preview"
          )
          .frame(width: 420, height: previewHeight)
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color(nsColor: .separatorColor))
          )
        }
      }
      .onPreferenceChange(SandboxfileWizardPolicyColumnHeightKey.self) { height in
        guard height > 0 else { return }
        policyColumnHeight = height
      }

      HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 4) {
          Text(request.repoSandboxfilePath)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

          Link("Full sandbox configuration docs", destination: SandboxfileHelpContent.docsURL)
            .font(.caption)
        }

        Spacer()

        Button("Cancel") {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)

        Button("Create and Launch") {
          onCreate(configuration)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("sandboxfile-wizard-create")
      }
    }
    .padding(24)
    .frame(width: 790)
  }

  private var previewText: Binding<String> {
    Binding(
      get: {
        configuration.renderProjectSandboxfile()
      },
      set: { _ in }
    )
  }

  private var highlightTheme: String {
    colorScheme == .dark ? "base16-ocean.dark" : "base16-ocean.light"
  }

  private var previewHeight: CGFloat {
    max(330, policyColumnHeight)
  }

  private var policyPickers: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Defaults")
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)

      policyRow("Network") {
        PillSelector(
          items: SandboxfileNetworkDefault.allCases,
          selection: $configuration.networkDefault,
          title: { $0.title }
        )
        .accessibilityIdentifier("sandboxfile-wizard-network-default")
      }

      policyRow("Commands") {
        PillSelector(
          items: SandboxfileExecDefault.allCases,
          selection: $configuration.executionDefault,
          title: { $0.title }
        )
        .accessibilityIdentifier("sandboxfile-wizard-exec-default")
      }
    }
  }

  private var repositoryAccess: some View {
    policySection("Repository") {
      SandboxfileWizardToggleRow(
        title: "Read files",
        detail: "Allow shells and agents to inspect this repository.",
        isOn: $configuration.allowRepositoryRead,
        accessibilityIdentifier: "sandboxfile-wizard-repository-read"
      )
      SandboxfileWizardToggleRow(
        title: "Write files",
        detail: "Allow edits inside this repository and its worktrees.",
        isOn: $configuration.allowRepositoryWrite,
        accessibilityIdentifier: "sandboxfile-wizard-repository-write",
        showsDivider: false
      )
    }
  }

  private var builtins: some View {
    policySection("Builtins") {
      ScrollView(.vertical) {
        VStack(spacing: 0) {
          ForEach(Array(SandboxfileWizardBuiltin.projectDefaults.enumerated()), id: \.element.id) {
            index,
            builtin in
            SandboxfileWizardToggleRow(
              title: builtin.name,
              detail: builtin.detail,
              isOn: builtinBinding(for: builtin),
              accessibilityIdentifier: "sandboxfile-wizard-builtin-\(builtin.name)",
              showsDivider: index < SandboxfileWizardBuiltin.projectDefaults.count - 1
            )
          }
        }
      }
      .frame(height: builtinsVisibleHeight)
    }
  }

  private var localOverrides: some View {
    policySection("Local") {
      SandboxfileWizardToggleRow(
        title: "Include Sandboxfile.local",
        detail: "Load an optional untracked local policy file for machine-specific rules.",
        isOn: $configuration.includeLocalOverrides,
        accessibilityIdentifier: "sandboxfile-wizard-local-overrides",
        showsDivider: false
      )
    }
  }

  private func policyRow<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Text(title)
        .font(.body)
        .frame(width: 84, alignment: .leading)

      content()
    }
  }

  private func policySection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)

      VStack(spacing: 0) {
        content()
      }
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )
    }
  }

  private var builtinsVisibleHeight: CGFloat {
    min(CGFloat(SandboxfileWizardBuiltin.projectDefaults.count), Self.maxVisibleBuiltinRows)
      * SandboxfileWizardToggleRow.rowHeight
  }

  private func builtinBinding(for builtin: SandboxfileWizardBuiltin) -> Binding<Bool> {
    Binding(
      get: {
        configuration.includesBuiltin(builtin)
      },
      set: { isEnabled in
        configuration.setBuiltin(builtin, isEnabled: isEnabled)
      }
    )
  }
}

private struct SandboxfileWizardToggleRow: View {
  static let rowHeight: CGFloat = 76

  let title: String
  let detail: String
  @Binding var isOn: Bool
  let accessibilityIdentifier: String
  var showsDivider = true

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Toggle("", isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
    .padding(.horizontal, 10)
    .frame(height: Self.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      if showsDivider {
        Divider()
      }
    }
  }
}

private struct SandboxfileWizardPolicyColumnHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
