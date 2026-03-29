use std::io;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::model::ReviewMode;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedReviewTarget {
    pub mode: ReviewMode,
    pub base_ref: String,
    pub head_ref: String,
    pub merge_base_sha: String,
}

#[derive(Debug, Error)]
pub enum TargetError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("git command failed: {0}")]
    Git(String),
    #[error("git output was not valid utf-8: {0}")]
    Utf8(#[from] std::string::FromUtf8Error),
    #[error("invalid git ref '{0}'")]
    InvalidRef(String),
    #[error("could not infer base ref; pass --base or use --pr")]
    MissingBaseRef,
    #[error("detached HEAD requires commit mode")]
    DetachedHead,
}

pub fn auto_detect_review_target(repo_root: &Path) -> Result<ResolvedReviewTarget, TargetError> {
    if is_head_detached(repo_root)? {
        return resolve_commit_target(repo_root, None);
    }

    let current_branch = current_branch_name(repo_root)?;
    let base_ref = infer_base_ref(repo_root)?;
    if shorten_ref(&base_ref) == current_branch {
        return resolve_commit_target(repo_root, None);
    }

    resolve_branch_target(repo_root, Some(&base_ref), Some(&current_branch))
}

pub fn resolve_branch_target(
    repo_root: &Path,
    base_input: Option<&str>,
    head_input: Option<&str>,
) -> Result<ResolvedReviewTarget, TargetError> {
    let base_ref = match base_input {
        Some(reference) => resolve_ref(repo_root, reference)?,
        None => infer_base_ref(repo_root)?,
    };
    let head_ref = match head_input {
        Some(reference) => resolve_ref(repo_root, reference)?,
        None => {
            let branch = current_branch_name(repo_root)?;
            resolve_ref(repo_root, &branch)?
        }
    };
    let merge_base_sha = git_capture(repo_root, &["merge-base", &base_ref, &head_ref])?;
    Ok(ResolvedReviewTarget {
        mode: ReviewMode::Branch,
        base_ref,
        head_ref,
        merge_base_sha,
    })
}

pub fn resolve_commit_target(
    repo_root: &Path,
    commit_input: Option<&str>,
) -> Result<ResolvedReviewTarget, TargetError> {
    let commit_ref = commit_input.unwrap_or("HEAD");
    let commit_sha = verify_commit_ref(repo_root, commit_ref)?;
    let base_ref = if commit_ref == "HEAD" {
        "HEAD".to_string()
    } else {
        commit_sha.clone()
    };

    Ok(ResolvedReviewTarget {
        mode: ReviewMode::Commit,
        base_ref,
        head_ref: "WORKTREE".to_string(),
        merge_base_sha: commit_sha,
    })
}

pub fn resolve_uncommitted_target(repo_root: &Path) -> Result<ResolvedReviewTarget, TargetError> {
    let merge_base_sha = verify_commit_ref(repo_root, "HEAD")?;

    Ok(ResolvedReviewTarget {
        mode: ReviewMode::Uncommitted,
        base_ref: "HEAD".to_string(),
        head_ref: "WORKTREE".to_string(),
        merge_base_sha,
    })
}

pub fn infer_base_ref(repo_root: &Path) -> Result<String, TargetError> {
    if let Ok(origin_head) = git_capture(
        repo_root,
        &[
            "symbolic-ref",
            "--quiet",
            "--short",
            "refs/remotes/origin/HEAD",
        ],
    ) {
        return Ok(origin_head);
    }

    for candidate in ["origin/main", "main", "origin/master", "master"] {
        if ensure_ref_exists(repo_root, candidate).is_ok() {
            return Ok(candidate.to_string());
        }
    }

    Err(TargetError::MissingBaseRef)
}

pub fn current_branch_name(repo_root: &Path) -> Result<String, TargetError> {
    let branch = git_capture(repo_root, &["rev-parse", "--abbrev-ref", "HEAD"])?;
    if branch == "HEAD" {
        return Err(TargetError::DetachedHead);
    }
    Ok(branch)
}

pub fn resolve_ref(repo_root: &Path, reference: &str) -> Result<String, TargetError> {
    let candidates = [reference.to_string(), format!("origin/{reference}")];
    for candidate in candidates {
        if ensure_ref_exists(repo_root, &candidate).is_ok() {
            return Ok(candidate);
        }
    }

    Err(TargetError::InvalidRef(reference.to_string()))
}

pub fn git_capture(repo_root: &Path, args: &[&str]) -> Result<String, TargetError> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(args)
        .output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(TargetError::Git(format!(
            "git {} failed: {stderr}",
            args.join(" ")
        )));
    }

    let stdout = String::from_utf8(output.stdout)?;
    Ok(stdout.trim().to_string())
}

fn ensure_ref_exists(repo_root: &Path, reference: &str) -> Result<(), TargetError> {
    verify_commit_ref(repo_root, reference).map(|_| ())
}

fn verify_commit_ref(repo_root: &Path, reference: &str) -> Result<String, TargetError> {
    let ref_name = format!("{reference}^{{commit}}");
    git_capture(repo_root, &["rev-parse", "--verify", &ref_name])
        .map_err(|_| TargetError::InvalidRef(reference.to_string()))
}

fn is_head_detached(repo_root: &Path) -> Result<bool, TargetError> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["symbolic-ref", "--quiet", "--short", "HEAD"])
        .output()?;
    Ok(!output.status.success())
}

fn shorten_ref(reference: &str) -> &str {
    reference.strip_prefix("origin/").unwrap_or(reference)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::process::Command;

    use anyhow::{Context, Result, bail};
    use tempfile::TempDir;

    use super::*;

    fn git(repo: &TempDir, args: &[&str]) -> Result<String> {
        let output = Command::new("git")
            .current_dir(repo.path())
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

    fn setup_repo_with_feature_branch() -> Result<(TempDir, TempDir)> {
        let repo = TempDir::new().context("create repo")?;
        let remote = TempDir::new().context("create remote")?;

        git(&repo, &["init"])?;
        git(&repo, &["config", "user.name", "Argon Test"])?;
        git(&repo, &["config", "user.email", "argon-test@example.com"])?;

        fs::write(repo.path().join("README.md"), "hello\n").context("write readme")?;
        git(&repo, &["add", "README.md"])?;
        git(&repo, &["commit", "-m", "init"])?;
        git(&repo, &["branch", "-M", "main"])?;

        let remote_path = remote.path().join("origin.git");
        let output = Command::new("git")
            .args(["init", "--bare", remote_path.to_string_lossy().as_ref()])
            .output()
            .context("init bare remote")?;
        if !output.status.success() {
            bail!(
                "git init --bare failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }

        git(
            &repo,
            &[
                "remote",
                "add",
                "origin",
                remote_path.to_string_lossy().as_ref(),
            ],
        )?;
        git(&repo, &["push", "-u", "origin", "main"])?;
        git(&repo, &["remote", "set-head", "origin", "main"])?;

        git(&repo, &["checkout", "-b", "feature/one"])?;
        fs::write(repo.path().join("README.md"), "hello\nfeature\n").context("update readme")?;
        git(&repo, &["commit", "-am", "feature update"])?;
        Ok((repo, remote))
    }

    #[test]
    fn auto_detect_prefers_branch_mode_on_feature_branch() -> Result<()> {
        let (repo, _remote) = setup_repo_with_feature_branch()?;
        let target = auto_detect_review_target(repo.path())?;

        assert_eq!(target.mode, ReviewMode::Branch);
        assert_eq!(target.base_ref, "origin/main");
        assert_eq!(target.head_ref, "feature/one");
        assert!(!target.merge_base_sha.is_empty());
        Ok(())
    }

    #[test]
    fn auto_detect_prefers_branch_mode_for_dirty_feature_branch() -> Result<()> {
        let (repo, _remote) = setup_repo_with_feature_branch()?;
        fs::write(repo.path().join("README.md"), "hello\nfeature\ndirty\n")
            .context("dirty write")?;

        let target = auto_detect_review_target(repo.path())?;
        assert_eq!(target.mode, ReviewMode::Branch);
        assert_eq!(target.base_ref, "origin/main");
        assert_eq!(target.head_ref, "feature/one");
        assert!(!target.merge_base_sha.is_empty());
        Ok(())
    }

    #[test]
    fn auto_detect_prefers_commit_mode_for_dirty_base_branch() -> Result<()> {
        let (repo, _remote) = setup_repo_with_feature_branch()?;
        git(&repo, &["checkout", "main"])?;
        fs::write(repo.path().join("README.md"), "hello\ndirty main\n").context("dirty write")?;

        let target = auto_detect_review_target(repo.path())?;
        assert_eq!(target.mode, ReviewMode::Commit);
        assert_eq!(target.base_ref, "HEAD");
        assert_eq!(target.head_ref, "WORKTREE");
        Ok(())
    }

    #[test]
    fn resolve_commit_uses_head_and_worktree_target() -> Result<()> {
        let (repo, _remote) = setup_repo_with_feature_branch()?;
        let expected_head = git(&repo, &["rev-parse", "HEAD"])?;

        let target = resolve_commit_target(repo.path(), None)?;
        assert_eq!(target.mode, ReviewMode::Commit);
        assert_eq!(target.base_ref, "HEAD");
        assert_eq!(target.head_ref, "WORKTREE");
        assert_eq!(target.merge_base_sha, expected_head);
        Ok(())
    }

    #[test]
    fn resolve_commit_with_explicit_ref_uses_resolved_sha() -> Result<()> {
        let (repo, _remote) = setup_repo_with_feature_branch()?;
        let expected = git(&repo, &["rev-parse", "HEAD~1"])?;

        let target = resolve_commit_target(repo.path(), Some("HEAD~1"))?;
        assert_eq!(target.mode, ReviewMode::Commit);
        assert_eq!(target.base_ref, expected);
        assert_eq!(target.head_ref, "WORKTREE");
        assert_eq!(target.merge_base_sha, expected);
        Ok(())
    }

    #[test]
    fn resolve_uncommitted_uses_head_to_worktree() -> Result<()> {
        let (repo, _remote) = setup_repo_with_feature_branch()?;
        let expected_head = git(&repo, &["rev-parse", "HEAD"])?;

        let target = resolve_uncommitted_target(repo.path())?;
        assert_eq!(target.mode, ReviewMode::Uncommitted);
        assert_eq!(target.base_ref, "HEAD");
        assert_eq!(target.head_ref, "WORKTREE");
        assert_eq!(target.merge_base_sha, expected_head);
        Ok(())
    }
}
