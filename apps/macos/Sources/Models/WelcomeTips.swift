import Foundation

struct WelcomeTip: Equatable, Identifiable {
  let id: String
  let title: String
  let message: String
}

enum WelcomeTips {
  // Add a tip here whenever a user-facing feature ships.
  static let all: [WelcomeTip] = [
    WelcomeTip(
      id: "open-from-terminal",
      title: "Open from Terminal",
      message: "Run argon <dir> to open a repository or worktree directly in Argon."
    ),
    WelcomeTip(
      id: "review-from-terminal",
      title: "Start Reviews from Terminal",
      message: "Run argon review <dir> to open the review UI for a repository."
    ),
    WelcomeTip(
      id: "new-worktree-shortcut",
      title: "Create Worktrees Quickly",
      message: "Press Command-N in a workspace to create a new worktree."
    ),
    WelcomeTip(
      id: "tab-navigation-shortcuts",
      title: "Move Between Tabs",
      message: "Use Command-Shift-Left and Command-Shift-Right to switch terminal tabs."
    ),
    WelcomeTip(
      id: "worktree-navigation-shortcuts",
      title: "Move Between Worktrees",
      message: "Use Command-Shift-Up and Command-Shift-Down to switch worktrees."
    ),
    WelcomeTip(
      id: "sandboxfile-wizard",
      title: "Sandbox Agents",
      message:
        "Create a Sandboxfile to choose what sandboxed agents can read, write, run, and access."
    ),
  ]
}

struct WelcomeTipRotator {
  static let defaultStorageKey = "welcomeTipNextIndex"

  var userDefaults: UserDefaults = .standard
  var storageKey: String = Self.defaultStorageKey
  var tips: [WelcomeTip] = WelcomeTips.all

  func nextTip() -> WelcomeTip? {
    guard !tips.isEmpty else { return nil }

    let storedIndex = userDefaults.integer(forKey: storageKey)
    let index = storedIndex.modulo(tips.count)
    userDefaults.set((index + 1).modulo(tips.count), forKey: storageKey)
    return tips[index]
  }
}

extension Int {
  fileprivate func modulo(_ divisor: Int) -> Int {
    ((self % divisor) + divisor) % divisor
  }
}
