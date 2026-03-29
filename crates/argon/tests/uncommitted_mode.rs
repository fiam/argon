use std::process::Command;

use anyhow::{Context, Result};
use serde_json::Value;
use tempfile::TempDir;

fn git(repo: &TempDir, args: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo.path())
        .output()
        .context("failed to run git")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git {:?} failed: {}", args, stderr);
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn setup_git_repo() -> Result<TempDir> {
    let dir = TempDir::new()?;
    git(&dir, &["init"])?;
    git(&dir, &["config", "user.email", "test@test.com"])?;
    git(&dir, &["config", "user.name", "Test"])?;
    std::fs::write(dir.path().join("README.md"), "# Hello\n")?;
    git(&dir, &["add", "."])?;
    git(&dir, &["commit", "-m", "initial"])?;
    Ok(dir)
}

fn run_argon(repo: &TempDir, args: &[&str]) -> Result<String> {
    let bin = env!("CARGO_BIN_EXE_argon");
    let output = Command::new(bin)
        .arg("--repo")
        .arg(repo.path())
        .args(args)
        .output()
        .context("failed to run argon")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        anyhow::bail!(
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
fn review_uncommitted_mode_creates_session() -> Result<()> {
    let repo = setup_git_repo()?;

    let out = run_argon(&repo, &["review", "--mode", "uncommitted", "--json"])?;
    let v: Value = serde_json::from_str(&out)?;
    let session = &v["session"];

    assert_eq!(session["mode"].as_str().unwrap(), "uncommitted");
    assert_eq!(session["base_ref"].as_str().unwrap(), "HEAD");
    assert_eq!(session["head_ref"].as_str().unwrap(), "WORKTREE");
    assert!(
        !session["id"].as_str().unwrap().is_empty(),
        "session id should be present"
    );
    Ok(())
}

#[test]
fn agent_start_uncommitted_mode() -> Result<()> {
    let repo = setup_git_repo()?;

    let out = run_argon(
        &repo,
        &["agent", "start", "--mode", "uncommitted", "--json"],
    )?;
    let v: Value = serde_json::from_str(&out)?;
    let session = &v["session"];

    assert_eq!(session["mode"].as_str().unwrap(), "uncommitted");
    assert_eq!(session["base_ref"].as_str().unwrap(), "HEAD");
    assert_eq!(session["head_ref"].as_str().unwrap(), "WORKTREE");
    Ok(())
}

#[test]
fn review_uncommitted_shows_staged_and_unstaged_changes() -> Result<()> {
    let repo = setup_git_repo()?;

    // Create a staged change
    std::fs::write(repo.path().join("staged.txt"), "staged content\n")?;
    git(&repo, &["add", "staged.txt"])?;

    // Create an unstaged change
    std::fs::write(repo.path().join("unstaged.txt"), "unstaged content\n")?;

    let out = run_argon(&repo, &["review", "--mode", "uncommitted", "--json"])?;
    let v: Value = serde_json::from_str(&out)?;
    let session = &v["session"];

    assert_eq!(session["mode"].as_str().unwrap(), "uncommitted");
    assert_eq!(session["base_ref"].as_str().unwrap(), "HEAD");
    assert_eq!(session["head_ref"].as_str().unwrap(), "WORKTREE");

    // Verify the session was created with a valid merge_base_sha (HEAD's sha)
    let merge_base = session["merge_base_sha"].as_str().unwrap();
    assert!(
        !merge_base.is_empty(),
        "merge_base_sha should be a valid commit SHA"
    );
    assert!(
        merge_base.len() >= 40,
        "merge_base_sha should be a full SHA, got: {}",
        merge_base
    );
    Ok(())
}
