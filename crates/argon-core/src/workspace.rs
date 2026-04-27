use std::io;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::model::ReviewMode;
use crate::target::{TargetError, auto_detect_review_target, git_capture, resolve_branch_target};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BranchTopology {
    pub ahead_count: u32,
    pub behind_count: u32,
}

impl BranchTopology {
    pub fn needs_rebase(&self) -> bool {
        self.behind_count > 0
    }

    pub fn can_fast_forward_base(&self) -> bool {
        self.ahead_count > 0 && self.behind_count == 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MergeabilityStatus {
    Unknown,
    Clean,
    Conflicted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeMergeability {
    pub status: MergeabilityStatus,
    pub base_ref: Option<String>,
    pub head_ref: Option<String>,
    pub merge_base_sha: Option<String>,
    pub topology: Option<BranchTopology>,
    pub detail: Option<String>,
}

impl WorktreeMergeability {
    fn unknown(detail: impl Into<String>) -> Self {
        Self {
            status: MergeabilityStatus::Unknown,
            base_ref: None,
            head_ref: None,
            merge_base_sha: None,
            topology: None,
            detail: Some(detail.into()),
        }
    }
}

#[derive(Debug, Error)]
pub enum WorkspaceError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("git command failed: {0}")]
    Git(String),
    #[error("git output was not valid utf-8: {0}")]
    Utf8(#[from] std::string::FromUtf8Error),
    #[error("invalid git output: {0}")]
    InvalidGitOutput(String),
    #[error(transparent)]
    Target(#[from] TargetError),
}

pub fn inspect_worktree_mergeability(
    worktree_path: &Path,
    base_ref: Option<&str>,
    head_ref: Option<&str>,
) -> WorktreeMergeability {
    match try_inspect_worktree_mergeability(worktree_path, base_ref, head_ref) {
        Ok(mergeability) => mergeability,
        Err(error) => WorktreeMergeability::unknown(error.to_string()),
    }
}

pub fn try_inspect_worktree_mergeability(
    worktree_path: &Path,
    base_ref: Option<&str>,
    head_ref: Option<&str>,
) -> Result<WorktreeMergeability, WorkspaceError> {
    let target = if base_ref.is_some() || head_ref.is_some() {
        resolve_branch_target(worktree_path, base_ref, head_ref)?
    } else {
        auto_detect_review_target(worktree_path)?
    };

    if target.mode != ReviewMode::Branch {
        return Ok(WorktreeMergeability {
            status: MergeabilityStatus::Unknown,
            base_ref: Some(target.base_ref),
            head_ref: Some(target.head_ref),
            merge_base_sha: Some(target.merge_base_sha),
            topology: None,
            detail: Some("mergeability only applies to branch review targets".to_string()),
        });
    }

    let topology = branch_topology(worktree_path, &target.base_ref, &target.head_ref)?;
    let is_conflicted = has_unmerged_files(worktree_path)?
        || merge_tree_conflicts(worktree_path, &target.base_ref, &target.head_ref)?;
    let status = if is_conflicted {
        MergeabilityStatus::Conflicted
    } else {
        MergeabilityStatus::Clean
    };

    Ok(WorktreeMergeability {
        status,
        base_ref: Some(target.base_ref),
        head_ref: Some(target.head_ref),
        merge_base_sha: Some(target.merge_base_sha),
        topology: Some(topology),
        detail: None,
    })
}

pub fn branch_topology(
    worktree_path: &Path,
    base_ref: &str,
    head_ref: &str,
) -> Result<BranchTopology, WorkspaceError> {
    let output = git_capture(
        worktree_path,
        &[
            "rev-list",
            "--left-right",
            "--count",
            &format!("{base_ref}...{head_ref}"),
        ],
    )?;
    let parts = output.split_whitespace().collect::<Vec<_>>();
    if parts.len() != 2 {
        return Err(WorkspaceError::InvalidGitOutput(format!(
            "expected two rev-list counts, got '{output}'"
        )));
    }

    let behind_count = parts[0].parse::<u32>().map_err(|_| {
        WorkspaceError::InvalidGitOutput(format!("invalid behind count '{}'", parts[0]))
    })?;
    let ahead_count = parts[1].parse::<u32>().map_err(|_| {
        WorkspaceError::InvalidGitOutput(format!("invalid ahead count '{}'", parts[1]))
    })?;

    Ok(BranchTopology {
        ahead_count,
        behind_count,
    })
}

fn has_unmerged_files(worktree_path: &Path) -> Result<bool, WorkspaceError> {
    let output = git_capture(worktree_path, &["diff", "--name-only", "--diff-filter=U"])?;
    Ok(!output.trim().is_empty())
}

fn merge_tree_conflicts(
    worktree_path: &Path,
    base_ref: &str,
    head_ref: &str,
) -> Result<bool, WorkspaceError> {
    let output = Command::new("git")
        .arg("-C")
        .arg(worktree_path)
        .args(["merge-tree", "--write-tree", "--quiet", base_ref, head_ref])
        .output()?;

    if output.status.success() {
        return Ok(false);
    }

    if output.status.code() == Some(1) {
        return Ok(true);
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(WorkspaceError::Git(format!(
        "git merge-tree --write-tree --quiet failed: {stderr}"
    )))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::process::Command;

    use anyhow::{Context, Result, bail};
    use tempfile::TempDir;

    use super::*;

    fn git(repo: &Path, args: &[&str]) -> Result<String> {
        let output = Command::new("git")
            .current_dir(repo)
            .args(args)
            .output()
            .with_context(|| format!("failed to execute git {}", args.join(" ")))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            bail!("git {} failed: {stderr}", args.join(" "));
        }

        let stdout = String::from_utf8(output.stdout).context("git output not utf-8")?;
        Ok(stdout.trim().to_string())
    }

    fn setup_repo_with_feature_worktree() -> Result<(TempDir, std::path::PathBuf)> {
        let fixture = TempDir::new().context("create fixture")?;
        let repo = fixture.path().join("repo");
        let worktree = fixture.path().join("feature");
        fs::create_dir_all(&repo).context("create repo")?;

        git(&repo, &["init"])?;
        git(&repo, &["config", "user.name", "Argon Test"])?;
        git(&repo, &["config", "user.email", "argon-test@example.com"])?;
        fs::write(repo.join("README.md"), "base\n").context("write readme")?;
        git(&repo, &["add", "README.md"])?;
        git(&repo, &["commit", "-m", "init"])?;
        git(&repo, &["branch", "-M", "main"])?;
        git(
            &repo,
            &[
                "worktree",
                "add",
                "-b",
                "feature/topic",
                worktree.to_str().unwrap(),
                "HEAD",
            ],
        )?;

        Ok((fixture, worktree))
    }

    #[test]
    fn mergeability_reports_clean_when_branches_do_not_conflict() -> Result<()> {
        let (_fixture, worktree) = setup_repo_with_feature_worktree()?;
        fs::write(worktree.join("feature.txt"), "feature\n").context("write feature")?;
        git(&worktree, &["add", "feature.txt"])?;
        git(&worktree, &["commit", "-m", "feature"])?;

        let mergeability = try_inspect_worktree_mergeability(&worktree, None, None)?;

        assert_eq!(mergeability.status, MergeabilityStatus::Clean);
        assert_eq!(mergeability.topology.unwrap().ahead_count, 1);
        Ok(())
    }

    #[test]
    fn mergeability_predicts_conflict_without_touching_worktree() -> Result<()> {
        let (fixture, worktree) = setup_repo_with_feature_worktree()?;
        let repo = fixture.path().join("repo");

        fs::write(repo.join("README.md"), "main\n").context("write main")?;
        git(&repo, &["commit", "-am", "main change"])?;
        fs::write(worktree.join("README.md"), "feature\n").context("write feature")?;
        git(&worktree, &["commit", "-am", "feature change"])?;

        let mergeability = try_inspect_worktree_mergeability(&worktree, None, None)?;
        let status = git(&worktree, &["status", "--porcelain"])?;

        assert_eq!(mergeability.status, MergeabilityStatus::Conflicted);
        assert!(
            status.is_empty(),
            "mergeability check must not dirty the worktree"
        );
        Ok(())
    }

    #[test]
    fn mergeability_reports_existing_unmerged_conflicts() -> Result<()> {
        let (fixture, worktree) = setup_repo_with_feature_worktree()?;
        let repo = fixture.path().join("repo");

        fs::write(repo.join("README.md"), "main\n").context("write main")?;
        git(&repo, &["commit", "-am", "main change"])?;
        fs::write(worktree.join("README.md"), "feature\n").context("write feature")?;
        git(&worktree, &["commit", "-am", "feature change"])?;

        let output = Command::new("git")
            .current_dir(&worktree)
            .args(["merge", "main"])
            .output()
            .context("run expected failing merge")?;
        assert!(!output.status.success(), "merge should conflict");

        let mergeability = try_inspect_worktree_mergeability(&worktree, None, None)?;

        assert_eq!(mergeability.status, MergeabilityStatus::Conflicted);
        Ok(())
    }
}
