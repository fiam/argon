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
fn dev_update_target_switches_mode() -> Result<()> {
    let repo = setup_git_repo()?;

    // Create a session in branch mode by providing explicit base/head.
    // We need a second commit so base != head.
    std::fs::write(repo.path().join("file.txt"), "content\n")?;
    git(&repo, &["add", "."])?;
    git(&repo, &["commit", "-m", "second"])?;

    let head_sha = git(&repo, &["rev-parse", "HEAD"])?;
    let base_sha = git(&repo, &["rev-parse", "HEAD~1"])?;

    let create_out = run_argon(
        &repo,
        &[
            "agent", "start", "--mode", "branch", "--base", &base_sha, "--head", &head_sha,
            "--json",
        ],
    )?;
    let create_v: Value = serde_json::from_str(&create_out)?;
    let session_id = create_v["session"]["id"]
        .as_str()
        .context("missing session.id")?;

    // Verify initial mode is branch
    assert_eq!(create_v["session"]["mode"].as_str().unwrap(), "branch");

    // Now update target to commit mode
    let update_out = run_argon(
        &repo,
        &[
            "agent",
            "dev",
            "update-target",
            "--session",
            session_id,
            "--mode",
            "commit",
            "--base-ref",
            "HEAD~1",
            "--head-ref",
            "HEAD",
            "--merge-base-sha",
            &base_sha,
            "--json",
        ],
    )?;
    let update_v: Value = serde_json::from_str(&update_out)?;
    let session = &update_v["session"];

    assert_eq!(
        session["mode"].as_str().unwrap(),
        "commit",
        "mode should have changed to commit"
    );
    assert_eq!(session["base_ref"].as_str().unwrap(), "HEAD~1");
    assert_eq!(session["head_ref"].as_str().unwrap(), "HEAD");
    assert_eq!(session["merge_base_sha"].as_str().unwrap(), &base_sha);

    // Verify the session ID is unchanged
    assert_eq!(session["id"].as_str().unwrap(), session_id);
    Ok(())
}
