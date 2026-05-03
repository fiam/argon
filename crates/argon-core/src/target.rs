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
    #[error("detached HEAD cannot infer a branch target")]
    DetachedHead,
}

pub fn auto_detect_review_target(repo_root: &Path) -> Result<ResolvedReviewTarget, TargetError> {
    if is_head_detached(repo_root)? {
        return resolve_uncommitted_target(repo_root);
    }

    let current_branch = current_branch_name(repo_root)?;
    let base_ref = infer_base_ref(repo_root)?;
    if shorten_ref(&base_ref) == current_branch {
        return resolve_uncommitted_target(repo_root);
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
    let current_branch = current_branch_name(repo_root).ok();

    if let Some(current_branch) = current_branch.as_deref() {
        if let Some(upstream) = upstream_ref(repo_root)?
            && shorten_ref(&upstream) != current_branch
        {
            return Ok(upstream);
        }

        if let Some(base_ref) = nearest_worktree_branch_base(repo_root, current_branch)? {
            return Ok(base_ref);
        }
    }

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

fn nearest_worktree_branch_base(
    repo_root: &Path,
    current_branch: &str,
) -> Result<Option<String>, TargetError> {
    let output = git_capture(repo_root, &["worktree", "list", "--porcelain"])?;
    let mut candidates = output
        .lines()
        .filter_map(|line| line.strip_prefix("branch "))
        .filter_map(|branch| branch.strip_prefix("refs/heads/"))
        .filter(|branch| *branch != current_branch)
        .map(str::to_string)
        .collect::<Vec<_>>();
    candidates.sort();
    candidates.dedup();

    let mut best: Option<(u8, u32, String)> = None;
    for candidate in candidates {
        if is_ancestor(repo_root, current_branch, &candidate)? {
            continue;
        }

        let merge_base = match git_capture(repo_root, &["merge-base", current_branch, &candidate]) {
            Ok(merge_base) => merge_base,
            Err(TargetError::Git(_)) => continue,
            Err(error) => return Err(error),
        };
        let distance = git_capture(
            repo_root,
            &[
                "rev-list",
                "--count",
                &format!("{merge_base}..{current_branch}"),
            ],
        )?;
        let Ok(distance) = distance.parse::<u32>() else {
            continue;
        };
        let tier = if is_ancestor(repo_root, &candidate, current_branch)? {
            0
        } else {
            1
        };

        match best.as_ref() {
            Some((best_tier, best_distance, best_ref))
                if (*best_tier, *best_distance, best_ref.as_str())
                    <= (tier, distance, candidate.as_str()) => {}
            _ => best = Some((tier, distance, candidate)),
        }
    }

    Ok(best.map(|(_, _, reference)| reference))
}

fn upstream_ref(repo_root: &Path) -> Result<Option<String>, TargetError> {
    match git_capture(
        repo_root,
        &["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
    ) {
        Ok(upstream) if !upstream.is_empty() => Ok(Some(upstream)),
        Ok(_) => Ok(None),
        Err(TargetError::Git(_)) => Ok(None),
        Err(error) => Err(error),
    }
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

fn is_ancestor(repo_root: &Path, ancestor: &str, descendant: &str) -> Result<bool, TargetError> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["merge-base", "--is-ancestor", ancestor, descendant])
        .output()?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Err(TargetError::Git(format!(
                "git merge-base --is-ancestor failed: {stderr}"
            )))
        }
    }
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
        git_path(repo.path(), args)
    }

    fn git_path(repo: &std::path::Path, args: &[&str]) -> Result<String> {
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
    fn auto_detect_prefers_uncommitted_mode_for_dirty_base_branch() -> Result<()> {
        let (repo, _remote) = setup_repo_with_feature_branch()?;
        git(&repo, &["checkout", "main"])?;
        fs::write(repo.path().join("README.md"), "hello\ndirty main\n").context("dirty write")?;

        let target = auto_detect_review_target(repo.path())?;
        assert_eq!(target.mode, ReviewMode::Uncommitted);
        assert_eq!(target.base_ref, "HEAD");
        assert_eq!(target.head_ref, "WORKTREE");
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

    #[test]
    fn auto_detect_uses_uncommitted_mode_for_detached_head() -> Result<()> {
        let (repo, _remote) = setup_repo_with_feature_branch()?;
        let expected_head = git(&repo, &["rev-parse", "HEAD"])?;
        git(&repo, &["checkout", "--detach", "HEAD"])?;

        let target = auto_detect_review_target(repo.path())?;
        assert_eq!(target.mode, ReviewMode::Uncommitted);
        assert_eq!(target.base_ref, "HEAD");
        assert_eq!(target.head_ref, "WORKTREE");
        assert_eq!(target.merge_base_sha, expected_head);
        Ok(())
    }

    #[test]
    fn infer_base_prefers_nearest_parent_worktree_branch() -> Result<()> {
        let fixture = TempDir::new().context("create fixture")?;
        let repo = fixture.path().join("repo");
        let parent = fixture.path().join("parent");
        let child = fixture.path().join("child");
        fs::create_dir_all(&repo).context("create repo")?;

        git_path(&repo, &["init"])?;
        git_path(&repo, &["config", "user.name", "Argon Test"])?;
        git_path(&repo, &["config", "user.email", "argon-test@example.com"])?;

        fs::write(repo.join("README.md"), "base\n").context("write readme")?;
        git_path(&repo, &["add", "README.md"])?;
        git_path(&repo, &["commit", "-m", "init"])?;
        git_path(&repo, &["branch", "-M", "main"])?;

        git_path(
            &repo,
            &[
                "worktree",
                "add",
                "-b",
                "parent/topic",
                parent.to_str().unwrap(),
                "HEAD",
            ],
        )?;
        fs::write(parent.join("README.md"), "base\nparent\n").context("write parent")?;
        git_path(&parent, &["commit", "-am", "parent"])?;

        git_path(
            &repo,
            &[
                "worktree",
                "add",
                "-b",
                "child/topic",
                child.to_str().unwrap(),
                "parent/topic",
            ],
        )?;
        fs::write(child.join("README.md"), "base\nparent\nchild\n").context("write child")?;
        git_path(&child, &["commit", "-am", "child"])?;

        assert_eq!(infer_base_ref(&child)?, "parent/topic");
        Ok(())
    }
}
