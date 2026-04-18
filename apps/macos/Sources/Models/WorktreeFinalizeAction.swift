import Foundation

enum WorktreeFinalizeAction: String, Identifiable, Sendable {
  case rebaseOntoBase
  case fastForwardToBase
  case mergeCommitToBase
  case rebaseAndMergeToBase
  case squashAndMergeToBase
  case openPullRequest

  var id: String { rawValue }

  var title: String {
    switch self {
    case .rebaseOntoBase:
      "rebase"
    case .fastForwardToBase:
      "fast-forward"
    case .mergeCommitToBase:
      "merge"
    case .rebaseAndMergeToBase:
      "rebase and merge"
    case .squashAndMergeToBase:
      "squash and merge"
    case .openPullRequest:
      "open a pull request"
    }
  }

  var optionTitle: String {
    switch self {
    case .rebaseOntoBase:
      "Rebase onto Base"
    case .fastForwardToBase:
      "Fast-Forward Base"
    case .mergeCommitToBase:
      "Create Merge Commit"
    case .rebaseAndMergeToBase:
      "Rebase and Merge"
    case .squashAndMergeToBase:
      "Squash and Merge"
    case .openPullRequest:
      "Open Pull Request"
    }
  }

  var launchSheetTitle: String {
    switch self {
    case .rebaseOntoBase:
      "Launch Rebase Agent"
    case .fastForwardToBase:
      "Launch Fast-Forward Agent"
    case .mergeCommitToBase:
      "Launch Merge Agent"
    case .rebaseAndMergeToBase:
      "Launch Rebase Agent"
    case .squashAndMergeToBase:
      "Launch Squash Agent"
    case .openPullRequest:
      "Launch PR Agent"
    }
  }

  var launchSheetSubtitle: String {
    switch self {
    case .rebaseOntoBase:
      "Launch an agent to rebase this worktree onto the base branch."
    case .fastForwardToBase:
      "Launch an agent to fast-forward the base branch to this worktree."
    case .mergeCommitToBase:
      "Launch an agent to merge this worktree back into the base branch."
    case .rebaseAndMergeToBase:
      "Launch an agent to rebase this worktree and land the rebased commits on the base branch."
    case .squashAndMergeToBase:
      "Launch an agent to squash this worktree and land it on the base branch."
    case .openPullRequest:
      "Launch an agent to open an upstream pull request for this worktree."
    }
  }

  var pickerSubtitle: String {
    switch self {
    case .rebaseOntoBase:
      "Select the live agent tab that should rebase this worktree onto the base branch."
    case .fastForwardToBase:
      "Select the live agent tab that should fast-forward the base branch to this worktree."
    case .mergeCommitToBase:
      "Select the live agent tab that should merge this worktree back into the base branch."
    case .rebaseAndMergeToBase:
      "Select the live agent tab that should rebase this worktree and land the rebased commits on the base branch."
    case .squashAndMergeToBase:
      "Select the live agent tab that should squash this worktree and land it on the base branch."
    case .openPullRequest:
      "Select the live agent tab that should open an upstream pull request for this worktree."
    }
  }

  var requiresBaseRepoWriteAccess: Bool {
    switch self {
    case .rebaseOntoBase:
      false
    case .fastForwardToBase, .mergeCommitToBase, .rebaseAndMergeToBase, .squashAndMergeToBase:
      true
    case .openPullRequest:
      false
    }
  }

  func prompt(
    repoRoot: String,
    worktreePath: String,
    branchName: String,
    baseRef: String,
    compareURL: String?
  ) -> String {
    let compareSection =
      if let compareURL, !compareURL.isEmpty {
        "\nSuggested compare URL: \(compareURL)"
      } else {
        ""
      }

    switch self {
    case .rebaseOntoBase:
      return """
        You are finalizing a linked Git worktree for Argon.

        Task: Rebase this worktree onto the base branch.
        Base worktree: \(repoRoot)
        Linked worktree: \(worktreePath)
        Feature branch: \(branchName)
        Base branch: \(baseRef)\(compareSection)

        Expectations:
        1. Rebase \(branchName) onto \(baseRef) in the linked worktree at \(worktreePath).
        2. Resolve conflicts carefully and validate the rebased result.
        3. Run the relevant tests before finishing.
        4. Do not merge into \(baseRef), open a pull request, or delete the worktree or branch.

        When you are done, summarize the rebase result, the new branch head, and any follow-up.
        """
    case .fastForwardToBase:
      return """
        You are finalizing a linked Git worktree for Argon.

        Task: Fast-forward the base branch to this worktree.
        Base worktree: \(repoRoot)
        Linked worktree: \(worktreePath)
        Feature branch: \(branchName)
        Base branch: \(baseRef)\(compareSection)

        Expectations:
        1. Validate the linked worktree changes first at \(worktreePath).
        2. Confirm \(baseRef) can be fast-forwarded to \(branchName).
        3. Advance \(baseRef) from the base worktree at \(repoRoot) without creating a merge commit.
        4. Run the relevant tests before finishing.
        5. Do not delete the worktree or branch after landing.

        When you are done, summarize the fast-forward result, the commit(s) that landed, and any follow-up.
        """
    case .mergeCommitToBase:
      return """
        You are finalizing a linked Git worktree for Argon.

        Task: Merge this worktree back into the base branch with a merge commit.
        Base worktree: \(repoRoot)
        Linked worktree: \(worktreePath)
        Feature branch: \(branchName)
        Base branch: \(baseRef)\(compareSection)

        Expectations:
        1. Validate the linked worktree changes first at \(worktreePath).
        2. Merge \(branchName) into \(baseRef) from the base worktree at \(repoRoot).
        3. Preserve commit history; do not squash or rewrite the branch first.
        4. Resolve conflicts carefully and run the relevant tests before finishing.
        5. Do not delete the worktree or branch after merging.

        When you are done, summarize the merge result, the commit(s) that landed, and any follow-up.
        """
    case .rebaseAndMergeToBase:
      return """
        You are finalizing a linked Git worktree for Argon.

        Task: Rebase this worktree and land the rebased commits on the base branch.
        Base worktree: \(repoRoot)
        Linked worktree: \(worktreePath)
        Feature branch: \(branchName)
        Base branch: \(baseRef)\(compareSection)

        Expectations:
        1. Rebase \(branchName) onto \(baseRef) in the linked worktree at \(worktreePath).
        2. Validate the rebased result and resolve conflicts carefully.
        3. Land the rebased commits onto \(baseRef) from the base worktree at \(repoRoot) without creating a merge commit.
        4. Run the relevant tests before finishing.
        5. Do not delete the worktree or branch after landing.

        When you are done, summarize the rebase, what landed on the base branch, and any follow-up.
        """
    case .squashAndMergeToBase:
      return """
        You are finalizing a linked Git worktree for Argon.

        Task: Squash this worktree and land it on the base branch.
        Base worktree: \(repoRoot)
        Linked worktree: \(worktreePath)
        Feature branch: \(branchName)
        Base branch: \(baseRef)\(compareSection)

        Expectations:
        1. Validate the linked worktree changes first at \(worktreePath).
        2. Land the work onto the base branch in \(repoRoot) as a single squashed commit.
        3. Choose a clear final commit message.
        4. Resolve conflicts carefully and run the relevant tests before finishing.
        5. Do not delete the worktree or branch after landing the squashed commit.

        When you are done, summarize the final commit, any conflicts you resolved, and any follow-up.
        """
    case .openPullRequest:
      return """
        You are finalizing a linked Git worktree for Argon.

        Task: Open an upstream pull request for this worktree.
        Base worktree: \(repoRoot)
        Linked worktree: \(worktreePath)
        Feature branch: \(branchName)
        Base branch: \(baseRef)\(compareSection)

        Expectations:
        1. Work from the linked worktree at \(worktreePath).
        2. Ensure the branch is pushed upstream if needed.
        3. Open a pull request targeting \(baseRef), preferably with `gh pr create` if available.
        4. If a pull request already exists, surface it instead of creating a duplicate.
        5. Do not merge or delete anything.

        When you are done, report the pull request URL and any follow-up the human should know about.
        """
    }
  }
}
