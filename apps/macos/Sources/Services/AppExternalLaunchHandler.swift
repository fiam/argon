import Foundation
import SwiftUI

@MainActor
final class AppExternalLaunchStore {
  static let shared = AppExternalLaunchStore()

  private var pendingURLs: [URL] = []

  private init() {}

  func enqueue(_ url: URL) {
    guard AppLaunchTarget.request(from: url) != nil else { return }
    pendingURLs.append(url)
    NotificationCenter.default.post(name: .argonExternalLaunchURL, object: nil)
  }

  func drain() -> [URL] {
    let urls = pendingURLs
    pendingURLs.removeAll()
    return urls
  }
}

extension Notification.Name {
  static let argonExternalLaunchURL = Notification.Name("ArgonExternalLaunchURL")
}

struct AppExternalLaunchHandler: ViewModifier {
  let recentProjects: RecentProjects
  let workspaceWindowRegistry: WorkspaceWindowRegistry

  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  func body(content: Content) -> some View {
    content
      .onAppear {
        handlePendingLaunches()
      }
      .onOpenURL { url in
        AppExternalLaunchStore.shared.enqueue(url)
        handlePendingLaunches()
      }
      .onReceive(NotificationCenter.default.publisher(for: .argonExternalLaunchURL)) { _ in
        handlePendingLaunches()
      }
  }

  @MainActor
  private func handlePendingLaunches() {
    for url in AppExternalLaunchStore.shared.drain() {
      guard let request = AppLaunchTarget.request(from: url) else { continue }
      handle(request)
    }
  }

  @MainActor
  private func handle(_ request: AppLaunchTarget.LaunchRequest) {
    switch request {
    case .workspace(let target):
      recentProjects.add(repoRoot: target.repoRoot)
      workspaceWindowRegistry.open(target: target) { target in
        openWindow(value: target)
      }
      dismissWindow(id: "welcome")
    case .review(let target):
      recentProjects.add(repoRoot: target.repoRoot)
      openWindow(value: target)
      dismissWindow(id: "welcome")
    }
  }
}

extension View {
  func appExternalLaunchHandler(
    recentProjects: RecentProjects,
    workspaceWindowRegistry: WorkspaceWindowRegistry
  ) -> some View {
    modifier(
      AppExternalLaunchHandler(
        recentProjects: recentProjects,
        workspaceWindowRegistry: workspaceWindowRegistry
      ))
  }
}
