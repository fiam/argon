import SwiftUI

struct FileTreePanel: View {
  let files: [FileDiff]
  let emptyTitle: String
  let emptySystemImage: String
  let emptyDescription: String
  let selectedFileID: String?
  let focusFilterRequest: Bool
  let onConsumeFocusFilterRequest: (() -> Void)?
  let onSelectFile: (FileDiff) -> Void
  let onOpenFile: ((FileDiff) -> Void)?

  @State private var filterText = ""
  @State private var showModeHelp = false
  @FocusState private var filterFocused: Bool

  private var isFilterEnabled: Bool {
    !files.isEmpty
  }

  private var currentMode: FilterMode {
    detectFilterMode(filterText)
  }

  private var filteredFiles: [FileDiff] {
    filterFiles(files, pattern: filterText)
  }

  private var treeNodes: [FileTreeNode] {
    buildFileTree(from: filteredFiles)
  }

  var body: some View {
    VStack(spacing: 0) {
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

            Text("\(filteredFiles.count)/\(files.count)")
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
      .onChange(of: focusFilterRequest) { _, focused in
        if focused && isFilterEnabled {
          filterFocused = true
          onConsumeFocusFilterRequest?()
        }
      }
      .onChange(of: files.isEmpty) { _, isEmpty in
        if isEmpty {
          filterFocused = false
        }
      }
      .disabled(!isFilterEnabled)
      .opacity(isFilterEnabled ? 1 : 0.45)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(height: 0.5)
      }

      if files.isEmpty {
        ContentUnavailableView(
          emptyTitle,
          systemImage: emptySystemImage,
          description: Text(emptyDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(treeNodes) { node in
              SharedFileTreeNodeView(
                node: node,
                depth: 0,
                selectedFileID: selectedFileID,
                onSelectFile: onSelectFile,
                onOpenFile: onOpenFile
              )
            }
          }
          .padding(.vertical, 2)
        }
      }
    }
  }
}

private struct SharedFileTreeNodeView: View {
  @Bindable var node: FileTreeNode
  let depth: Int
  let selectedFileID: String?
  let onSelectFile: (FileDiff) -> Void
  let onOpenFile: ((FileDiff) -> Void)?

  var body: some View {
    if node.isDirectory {
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
          SharedFileTreeNodeView(
            node: child,
            depth: depth + 1,
            selectedFileID: selectedFileID,
            onSelectFile: onSelectFile,
            onOpenFile: onOpenFile
          )
        }
      }
    } else if let file = node.file {
      SharedFileTreeFileRow(
        file: file,
        name: node.name,
        depth: depth,
        isSelected: selectedFileID == file.id,
        onSelect: {
          onSelectFile(file)
        },
        onOpen: {
          onOpenFile?(file)
        }
      )
    }
  }
}

private struct SharedFileTreeFileRow: View {
  let file: FileDiff
  let name: String
  let depth: Int
  let isSelected: Bool
  let onSelect: () -> Void
  let onOpen: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 4) {
        Spacer().frame(width: 12)
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
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        onOpen()
      }
    )
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
