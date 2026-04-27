use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::Value;
use tempfile::TempDir;

fn git(repo: &Path, args: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo)
        .output()
        .context("failed to run git")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("git {:?} failed: {}", args, stderr);
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn setup_workspace() -> Result<(TempDir, PathBuf, PathBuf)> {
    let fixture = TempDir::new()?;
    let repo = fixture.path().join("repo");
    let worktree = fixture.path().join("feature");
    fs::create_dir_all(&repo)?;

    git(&repo, &["init"])?;
    git(&repo, &["config", "user.email", "test@test.com"])?;
    git(&repo, &["config", "user.name", "Test"])?;
    fs::write(repo.join("conflict.txt"), "base\n")?;
    git(&repo, &["add", "conflict.txt"])?;
    git(&repo, &["commit", "-m", "initial"])?;
    git(&repo, &["branch", "-M", "main"])?;
    git(
        &repo,
        &[
            "worktree",
            "add",
            "-b",
            "feature/conflict",
            worktree.to_str().unwrap(),
            "HEAD",
        ],
    )?;

    Ok((fixture, repo, worktree))
}

fn run_argon(repo: &Path, args: &[&str]) -> Result<String> {
    let bin = env!("CARGO_BIN_EXE_argon");
    let output = Command::new(bin)
        .arg("--repo")
        .arg(repo)
        .args(args)
        .output()
        .context("failed to run argon")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        bail!(
            "argon {:?} failed (exit {:?}):\nstdout: {}\nstderr: {}",
            args,
            output.status.code(),
            stdout,
            stderr
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[test]
fn workspace_mergeability_reports_clean_branch() -> Result<()> {
    let (_fixture, _repo, worktree) = setup_workspace()?;
    fs::write(worktree.join("feature.txt"), "feature\n")?;
    git(&worktree, &["add", "feature.txt"])?;
    git(&worktree, &["commit", "-m", "feature"])?;

    let output = run_argon(&worktree, &["workspace", "mergeability", "--json"])?;
    let value: Value = serde_json::from_str(&output)?;

    assert_eq!(value["schema_version"].as_str(), Some("v1"));
    assert_eq!(value["mergeability"]["status"].as_str(), Some("clean"));
    assert_eq!(
        value["mergeability"]["topology"]["ahead_count"].as_u64(),
        Some(1)
    );
    Ok(())
}

#[test]
fn workspace_mergeability_predicts_conflict_without_dirtying_worktree() -> Result<()> {
    let (_fixture, repo, worktree) = setup_workspace()?;
    fs::write(repo.join("conflict.txt"), "main\n")?;
    git(&repo, &["commit", "-am", "main"])?;
    fs::write(worktree.join("conflict.txt"), "feature\n")?;
    git(&worktree, &["commit", "-am", "feature"])?;

    let output = run_argon(&worktree, &["workspace", "mergeability", "--json"])?;
    let value: Value = serde_json::from_str(&output)?;
    let status = git(&worktree, &["status", "--porcelain"])?;

    assert_eq!(value["mergeability"]["status"].as_str(), Some("conflicted"));
    assert!(
        status.is_empty(),
        "mergeability inspection must not mutate the worktree"
    );
    Ok(())
}
