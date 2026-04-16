import Foundation

extension Notification.Name {
  static let reviewSessionDidClose = Notification.Name("Argon.reviewSessionDidClose")
}

enum ReviewSessionLifecycle {
  private static let repoRootUserInfoKey = "repoRoot"

  static func postSessionClosed(repoRoot: String) {
    NotificationCenter.default.post(
      name: .reviewSessionDidClose,
      object: nil,
      userInfo: [repoRootUserInfoKey: repoRoot]
    )
  }

  static func repoRoot(from notification: Notification) -> String? {
    notification.userInfo?[repoRootUserInfoKey] as? String
  }
}
