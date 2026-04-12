import AppKit
import SwiftUI

struct AppKitDiffViewport: NSViewControllerRepresentable {
  let document: DiffDocument
  let appState: AppState

  func makeNSViewController(context: Context) -> DiffViewportController {
    DiffViewportController()
  }

  func updateNSViewController(_ controller: DiffViewportController, context: Context) {
    controller.update(document: document, appState: appState)
  }
}

final class DiffViewportController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  private struct ScrollSnapshot {
    let anchor: DiffAnchor
    let visibleOffset: CGFloat
  }

  private enum ScrollRestoreSnapshot {
    case anchor(ScrollSnapshot)
    case origin(CGFloat)
  }

  private let containerView = NSView()
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff-column"))
  private var stickyHeaderView: NSHostingView<AnyView>?
  private var stickyHeaderTopConstraint: NSLayoutConstraint?
  private var stickyHeaderHeightConstraint: NSLayoutConstraint?
  private var document = DiffDocument(rows: [])
  private weak var appState: AppState?
  private var lastNavigationRequestID: UUID?

  override func loadView() {
    column.resizingMask = .autoresizingMask
    column.title = "Diff"

    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.delegate = self
    tableView.dataSource = self
    tableView.usesAutomaticRowHeights = true
    tableView.intercellSpacing = .zero
    tableView.selectionHighlightStyle = .none
    tableView.focusRingType = .none
    tableView.backgroundColor = .textBackgroundColor
    tableView.style = .plain
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.borderType = .noBorder
    scrollView.documentView = tableView
    scrollView.contentView.postsBoundsChangedNotifications = true

    containerView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    containerView.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
    ])

    view = containerView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(contentBoundsDidChange),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func update(document: DiffDocument, appState: AppState) {
    let previousRowIDs = self.document.rows.map(\.id)
    let viewportRestoreRequest = appState.diffViewportRestoreRequest
    let scrollSnapshot: ScrollRestoreSnapshot? =
      switch viewportRestoreRequest?.mode {
      case .origin:
        .origin(scrollView.contentView.documentVisibleRect.minY)
      case .gapAnchor:
        captureScrollSnapshot(for: viewportRestoreRequest?.anchor).map(ScrollRestoreSnapshot.anchor)
      case .nextVisibleRow:
        captureAdjacentScrollSnapshot(
          for: viewportRestoreRequest?.anchor,
          rowOffset: 1
        ).map(ScrollRestoreSnapshot.anchor)
      case .previousVisibleRow:
        captureAdjacentScrollSnapshot(
          for: viewportRestoreRequest?.anchor,
          rowOffset: -1
        ).map(ScrollRestoreSnapshot.anchor)
      case .none:
        captureScrollSnapshot(for: viewportRestoreRequest?.anchor).map(ScrollRestoreSnapshot.anchor)
      }

    self.document = document
    self.appState = appState

    tableView.reloadData()
    if !document.rows.isEmpty {
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<document.rows.count))
    }
    if let scrollSnapshot {
      restoreScrollSnapshot(scrollSnapshot)
    }
    if let viewportRestoreRequest, previousRowIDs != document.rows.map(\.id) {
      appState.clearDiffViewportRestoreRequest(viewportRestoreRequest.id)
    }
    updateStickyHeader()
    performNavigationIfNeeded()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    document.rows.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard row >= 0, row < document.rows.count, let appState else { return nil }

    let identifier = NSUserInterfaceItemIdentifier("diff-row-hosting-cell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? DiffRowHostingCellView
      ?? DiffRowHostingCellView()
    cell.identifier = identifier
    cell.host(
      row: document.rows[row],
      appState: appState,
      showTopSeparator: shouldShowTopSeparator(forRow: row)
    )
    return cell
  }

  private func shouldShowTopSeparator(forRow row: Int) -> Bool {
    guard row > 0, row < document.rows.count else { return false }
    guard case .fileHeader = document.rows[row].payload else { return false }
    return true
  }

  private func performNavigationIfNeeded() {
    guard let appState, let request = appState.diffNavigationRequest else { return }
    guard request.id != lastNavigationRequestID else { return }

    lastNavigationRequestID = request.id

    DispatchQueue.main.async { [weak self] in
      guard let self, let appState = self.appState else { return }
      let fallbackAnchor = request.fallbackFileID.map(DiffAnchor.file)
      let targetAnchor =
        self.document.contains(anchor: request.anchor)
        ? request.anchor : fallbackAnchor

      guard let targetAnchor, let row = self.document.index(for: targetAnchor)
      else {
        appState.clearDiffNavigationRequest(request.id)
        self.lastNavigationRequestID = nil
        return
      }

      self.scroll(toRow: row, alignment: request.alignment, animated: request.animated)
      appState.clearDiffNavigationRequest(request.id)
      self.lastNavigationRequestID = nil
    }
  }

  private func scroll(toRow row: Int, alignment: DiffNavigationAlignment, animated: Bool) {
    guard row >= 0, row < tableView.numberOfRows else { return }
    tableView.scrollRowToVisible(row)
    adjustScroll(toRow: row, alignment: alignment, animated: animated, remainingPasses: 3)
  }

  private func adjustScroll(
    toRow row: Int,
    alignment: DiffNavigationAlignment,
    animated: Bool,
    remainingPasses: Int
  ) {
    guard row >= 0, row < tableView.numberOfRows else { return }

    view.layoutSubtreeIfNeeded()
    tableView.layoutSubtreeIfNeeded()

    let rowRect = tableView.rect(ofRow: row)
    let clipView = scrollView.contentView
    let viewportHeight = clipView.bounds.height
    let documentHeight = tableView.bounds.height
    let maxOriginY = max(0, documentHeight - viewportHeight)

    let desiredOriginY: CGFloat
    if tableView.isFlipped {
      switch alignment {
      case .top:
        desiredOriginY = rowRect.minY
      case .center:
        desiredOriginY = rowRect.midY - (viewportHeight / 2)
      }
    } else {
      switch alignment {
      case .top:
        desiredOriginY = documentHeight - rowRect.maxY
      case .center:
        desiredOriginY = documentHeight - rowRect.midY - (viewportHeight / 2)
      }
    }

    let point = NSPoint(x: 0, y: min(max(desiredOriginY, 0), maxOriginY))

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        clipView.animator().setBoundsOrigin(point)
      } completionHandler: {
        Task { @MainActor in
          self.scrollView.reflectScrolledClipView(clipView)
          self.updateStickyHeader()
          if remainingPasses > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
              self.adjustScroll(
                toRow: row,
                alignment: alignment,
                animated: false,
                remainingPasses: remainingPasses - 1
              )
            }
          }
        }
      }
    } else {
      clipView.scroll(to: point)
      scrollView.reflectScrolledClipView(clipView)
      updateStickyHeader()
      if remainingPasses > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
          self.adjustScroll(
            toRow: row,
            alignment: alignment,
            animated: false,
            remainingPasses: remainingPasses - 1
          )
        }
      }
    }
  }

  @objc private func contentBoundsDidChange() {
    updateStickyHeader()
  }

  private func updateStickyHeader() {
    guard let file = currentFloatingHeaderFile() else {
      stickyHeaderView?.isHidden = true
      return
    }

    let rootView = AnyView(
      DiffFileHeader(
        file: file,
        showSplitGuide: appState?.diffMode == .sideBySide,
        isFloating: true,
        showTopSeparator: true
      )
      .background(Color(nsColor: .controlBackgroundColor))
    )

    let hostingView: NSHostingView<AnyView>
    if let stickyHeaderView {
      hostingView = stickyHeaderView
      hostingView.rootView = rootView
      hostingView.isHidden = false
    } else {
      hostingView = NSHostingView(rootView: rootView)
      hostingView.translatesAutoresizingMaskIntoConstraints = false
      hostingView.wantsLayer = true
      hostingView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
      containerView.addSubview(hostingView)
      let topConstraint = hostingView.topAnchor.constraint(equalTo: containerView.topAnchor)
      let heightConstraint = hostingView.heightAnchor.constraint(equalToConstant: 32)
      NSLayoutConstraint.activate([
        hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
        hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        topConstraint,
        heightConstraint,
      ])
      stickyHeaderTopConstraint = topConstraint
      stickyHeaderHeightConstraint = heightConstraint
      stickyHeaderView = hostingView
    }

    hostingView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    stickyHeaderTopConstraint?.constant = 0
    hostingView.layoutSubtreeIfNeeded()
    stickyHeaderHeightConstraint?.constant = max(1, hostingView.fittingSize.height)
  }

  private func captureScrollSnapshot(for anchor: DiffAnchor? = nil) -> ScrollSnapshot? {
    guard !document.rows.isEmpty else { return nil }

    let visibleRect = scrollView.contentView.documentVisibleRect
    if let anchor,
      let row = document.index(for: anchor),
      row < document.rows.count
    {
      let rowRect = tableView.rect(ofRow: row)
      return ScrollSnapshot(
        anchor: anchor,
        visibleOffset: visibleRect.minY - rowRect.minY
      )
    }

    let rowsRange = tableView.rows(in: visibleRect)
    guard rowsRange.length > 0 else { return nil }
    let topRow = max(0, rowsRange.location)
    guard topRow < document.rows.count else { return nil }

    let rowRect = tableView.rect(ofRow: topRow)
    return ScrollSnapshot(
      anchor: document.rows[topRow].anchor,
      visibleOffset: visibleRect.minY - rowRect.minY
    )
  }

  private func captureAdjacentScrollSnapshot(
    for anchor: DiffAnchor?,
    rowOffset: Int
  ) -> ScrollSnapshot? {
    guard let anchor, let row = document.index(for: anchor) else {
      return captureScrollSnapshot(for: anchor)
    }

    let adjacentRow = row + rowOffset
    guard adjacentRow >= 0, adjacentRow < document.rows.count else {
      return captureScrollSnapshot(for: anchor) ?? captureScrollSnapshot()
    }

    return captureScrollSnapshot(for: document.rows[adjacentRow].anchor)
  }

  private func restoreScrollSnapshot(_ snapshot: ScrollRestoreSnapshot) {
    switch snapshot {
    case .anchor(let snapshot):
      restoreAnchorScrollSnapshot(snapshot)
    case .origin(let originY):
      restoreOriginScrollSnapshot(originY)
    }
  }

  private func restoreAnchorScrollSnapshot(_ snapshot: ScrollSnapshot) {
    guard let row = document.index(for: snapshot.anchor), row < tableView.numberOfRows else {
      return
    }

    view.layoutSubtreeIfNeeded()
    tableView.layoutSubtreeIfNeeded()

    let rowRect = tableView.rect(ofRow: row)
    let clipView = scrollView.contentView
    let viewportHeight = clipView.bounds.height
    let documentHeight = tableView.bounds.height
    let maxOriginY = max(0, documentHeight - viewportHeight)
    let originY = min(max(rowRect.minY + snapshot.visibleOffset, 0), maxOriginY)

    clipView.scroll(to: NSPoint(x: 0, y: originY))
    scrollView.reflectScrolledClipView(clipView)
  }

  private func restoreOriginScrollSnapshot(_ originY: CGFloat) {
    view.layoutSubtreeIfNeeded()
    tableView.layoutSubtreeIfNeeded()

    let clipView = scrollView.contentView
    let viewportHeight = clipView.bounds.height
    let documentHeight = tableView.bounds.height
    let maxOriginY = max(0, documentHeight - viewportHeight)
    let clampedOriginY = min(max(originY, 0), maxOriginY)

    clipView.scroll(to: NSPoint(x: 0, y: clampedOriginY))
    scrollView.reflectScrolledClipView(clipView)
  }

  private func currentFloatingHeaderFile() -> FileDiff? {
    guard !document.rows.isEmpty else { return nil }

    let visibleRect = scrollView.contentView.documentVisibleRect
    let rowsRange = tableView.rows(in: visibleRect)
    guard rowsRange.length > 0 else { return nil }

    let topRow = max(0, rowsRange.location)
    let topRowRect = tableView.rect(ofRow: topRow)
    let topRowData = document.rows[topRow]

    if case .fileHeader = topRowData.payload,
      abs(topRowRect.minY - visibleRect.minY) < 1
    {
      return nil
    }

    for rowIndex in stride(from: topRow, through: 0, by: -1) {
      if case .fileHeader(let file) = document.rows[rowIndex].payload {
        return file
      }
    }

    return nil
  }
}

final class DiffRowHostingCellView: NSTableCellView {
  private var hostingView: NSHostingView<AnyView>?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func host(row: DiffDocumentRow, appState: AppState, showTopSeparator: Bool) {
    let rootView = AnyView(
      DiffDocumentRowView(row: row, showTopSeparator: showTopSeparator)
        .environment(appState)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    )

    if let hostingView {
      hostingView.rootView = rootView
      return
    }

    let hostingView = NSHostingView(rootView: rootView)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    self.hostingView = hostingView
  }
}

private struct DiffDocumentRowView: View {
  @Environment(AppState.self) private var appState
  let row: DiffDocumentRow
  let showTopSeparator: Bool

  var body: some View {
    switch row.payload {
    case .orphanedThread(let thread):
      OrphanedThreadRow(thread: thread)
    case .fileHeader(let file):
      DiffFileHeader(
        file: file,
        showSplitGuide: appState.diffMode == .sideBySide,
        showTopSeparator: showTopSeparator
      )
    case .omittedContext(let block):
      DiffOmittedContextRow(block: block)
    case .hunkHeader(_, let hunk):
      DiffHunkHeaderRow(hunk: hunk)
    case .unifiedLine(let filePath, let line):
      DiffLineView(line: line, filePath: filePath)
    case .sideBySidePair(let filePath, let pair):
      SideBySideRowView(pair: pair, filePath: filePath)
    case .inlineThread(let thread, let isOutdated):
      inlinePlacement {
        InlineThreadView(thread: thread, isOutdated: isOutdated)
      }
    case .inlineDraft(let draft):
      inlinePlacement {
        InlineDraftView(draft: draft)
      }
    case .commentEditor(let filePath, let line):
      inlinePlacement {
        InlineCommentEditor(filePath: filePath, line: line)
      }
    }
  }

  @ViewBuilder
  private func inlinePlacement<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    switch row.placement {
    case .fullWidth:
      content()
    case .split(let side):
      SplitInlineRow(side: side) {
        content()
      }
    }
  }
}

private struct SplitInlineRow<Content: View>: View {
  let side: DiffSplitSide
  private let content: Content

  init(side: DiffSplitSide, @ViewBuilder content: () -> Content) {
    self.side = side
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 0) {
      pane(.left)
      Divider()
      pane(.right)
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  @ViewBuilder
  private func pane(_ paneSide: DiffSplitSide) -> some View {
    Group {
      if paneSide == side {
        content
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Color.clear
          .frame(maxWidth: .infinity, minHeight: 1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct DiffHunkHeaderRow: View {
  let hunk: DiffHunk

  var body: some View {
    HStack(spacing: 0) {
      Text(hunk.header)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
      Spacer()
    }
    .background(Color.blue.opacity(0.06))
  }
}

private struct DiffOmittedContextRow: View {
  @Environment(AppState.self) private var appState
  let block: DiffOmittedContextBlock

  var body: some View {
    HStack(spacing: 10) {
      Button {
        appState.expandOmittedContext(block, direction: .up)
      } label: {
        Label("Expand Up", systemImage: "chevron.up")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.plain)
      .help("Show more context above")

      Button {
        appState.expandOmittedContext(block, direction: .all)
      } label: {
        Text("Show \(block.hiddenLineCount) more lines")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)

      Button {
        appState.expandOmittedContext(block, direction: .down)
      } label: {
        Label("Expand Down", systemImage: "chevron.down")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.plain)
      .help("Show more context below")

      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(height: 0.5)
    }
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(height: 0.5)
    }
  }
}

private struct OrphanedThreadRow: View {
  let thread: ReviewThread

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let anchor = thread.comments.first?.anchor, let filePath = anchor.filePath {
        HStack(spacing: 6) {
          Image(systemName: "archivebox")
            .font(.caption2)
            .foregroundStyle(.orange)
          Text(filePath)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
          if let line = anchor.lineNew ?? anchor.lineOld {
            Text(":\(line)")
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.tertiary)
          }
          Spacer()
          Text("file not in diff")
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.15))
            .foregroundStyle(.orange)
            .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
      }
      InlineThreadView(thread: thread, isOutdated: true)
    }
    .background(Color.orange.opacity(0.03))
  }
}
