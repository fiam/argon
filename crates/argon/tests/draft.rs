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

/// Creates a session and returns its ID.
fn create_session(repo: &TempDir) -> Result<String> {
    let out = run_argon(repo, &["review", "--mode", "uncommitted", "--json"])?;
    let v: Value = serde_json::from_str(&out)?;
    let id = v["session"]["id"]
        .as_str()
        .context("missing session.id")?
        .to_string();
    Ok(id)
}

#[test]
fn draft_add_creates_pending_comment() -> Result<()> {
    let repo = setup_git_repo()?;
    let session_id = create_session(&repo)?;

    let out = run_argon(
        &repo,
        &[
            "draft",
            "add",
            "--session",
            &session_id,
            "--message",
            "fix this",
            "--file",
            "README.md",
            "--line-new",
            "1",
            "--json",
        ],
    )?;
    let v: Value = serde_json::from_str(&out)?;
    let comments = v["comments"].as_array().context("missing comments array")?;
    assert!(!comments.is_empty(), "expected at least one draft comment");
    let last = comments.last().unwrap();
    assert_eq!(last["body"].as_str().unwrap(), "fix this");
    assert_eq!(last["anchor"]["file_path"].as_str().unwrap(), "README.md");
    assert_eq!(last["anchor"]["line_new"].as_u64().unwrap(), 1);
    Ok(())
}

#[test]
fn draft_add_global_comment() -> Result<()> {
    let repo = setup_git_repo()?;
    let session_id = create_session(&repo)?;

    let out = run_argon(
        &repo,
        &[
            "draft",
            "add",
            "--session",
            &session_id,
            "--message",
            "general feedback",
            "--json",
        ],
    )?;
    let v: Value = serde_json::from_str(&out)?;
    let comments = v["comments"].as_array().context("missing comments array")?;
    assert!(!comments.is_empty());
    let last = comments.last().unwrap();
    assert_eq!(last["body"].as_str().unwrap(), "general feedback");
    assert!(
        last["anchor"]["file_path"].is_null(),
        "global comment should have no file_path"
    );
    assert!(
        last["anchor"]["line_new"].is_null(),
        "global comment should have no line_new"
    );
    Ok(())
}

#[test]
fn draft_list_shows_pending_drafts() -> Result<()> {
    let repo = setup_git_repo()?;
    let session_id = create_session(&repo)?;

    run_argon(
        &repo,
        &[
            "draft",
            "add",
            "--session",
            &session_id,
            "--message",
            "first comment",
            "--json",
        ],
    )?;
    run_argon(
        &repo,
        &[
            "draft",
            "add",
            "--session",
            &session_id,
            "--message",
            "second comment",
            "--json",
        ],
    )?;

    let out = run_argon(
        &repo,
        &["draft", "list", "--session", &session_id, "--json"],
    )?;
    let v: Value = serde_json::from_str(&out)?;
    let comments = v["comments"].as_array().context("missing comments array")?;
    assert_eq!(
        comments.len(),
        2,
        "expected two draft comments, got {}",
        comments.len()
    );

    let bodies: Vec<&str> = comments
        .iter()
        .map(|c| c["body"].as_str().unwrap())
        .collect();
    assert!(bodies.contains(&"first comment"));
    assert!(bodies.contains(&"second comment"));
    Ok(())
}

#[test]
fn draft_delete_removes_comment() -> Result<()> {
    let repo = setup_git_repo()?;
    let session_id = create_session(&repo)?;

    let add_out = run_argon(
        &repo,
        &[
            "draft",
            "add",
            "--session",
            &session_id,
            "--message",
            "to be deleted",
            "--json",
        ],
    )?;
    let add_v: Value = serde_json::from_str(&add_out)?;
    let draft_id = add_v["comments"]
        .as_array()
        .and_then(|arr| arr.last())
        .and_then(|c| c["id"].as_str())
        .context("missing draft comment id")?;

    let del_out = run_argon(
        &repo,
        &[
            "draft",
            "delete",
            "--session",
            &session_id,
            "--draft-id",
            draft_id,
            "--json",
        ],
    )?;
    let del_v: Value = serde_json::from_str(&del_out)?;
    let remaining = del_v["comments"]
        .as_array()
        .context("missing comments array")?;
    assert!(
        remaining.is_empty(),
        "expected no draft comments after deletion, got {}",
        remaining.len()
    );
    Ok(())
}

#[test]
fn draft_submit_materializes_comments_and_sets_decision() -> Result<()> {
    let repo = setup_git_repo()?;
    let session_id = create_session(&repo)?;

    run_argon(
        &repo,
        &[
            "draft",
            "add",
            "--session",
            &session_id,
            "--message",
            "needs work",
            "--file",
            "README.md",
            "--line-new",
            "1",
            "--json",
        ],
    )?;
    run_argon(
        &repo,
        &[
            "draft",
            "add",
            "--session",
            &session_id,
            "--message",
            "also this",
            "--json",
        ],
    )?;

    let out = run_argon(
        &repo,
        &[
            "draft",
            "submit",
            "--session",
            &session_id,
            "--outcome",
            "changes-requested",
            "--json",
        ],
    )?;
    let v: Value = serde_json::from_str(&out)?;
    let session = &v["session"];

    // Verify threads were created from the submitted draft comments
    let threads = session["threads"]
        .as_array()
        .context("missing threads array")?;
    assert!(
        threads.len() >= 2,
        "expected at least 2 threads after submit, got {}",
        threads.len()
    );

    // Verify decision was set
    let decision = &session["decision"];
    assert!(
        !decision.is_null(),
        "expected decision to be set after submit with outcome"
    );
    assert_eq!(decision["outcome"].as_str().unwrap(), "changes_requested");
    Ok(())
}

#[test]
fn draft_submit_without_outcome_just_submits_comments() -> Result<()> {
    let repo = setup_git_repo()?;
    let session_id = create_session(&repo)?;

    run_argon(
        &repo,
        &[
            "draft",
            "add",
            "--session",
            &session_id,
            "--message",
            "just a note",
            "--json",
        ],
    )?;

    let out = run_argon(
        &repo,
        &["draft", "submit", "--session", &session_id, "--json"],
    )?;
    let v: Value = serde_json::from_str(&out)?;
    let session = &v["session"];

    // Verify comments were materialized into threads
    let threads = session["threads"]
        .as_array()
        .context("missing threads array")?;
    assert!(
        !threads.is_empty(),
        "expected at least one thread after submit"
    );

    // Verify no decision was set (no --outcome flag)
    assert!(
        session["decision"].is_null(),
        "expected no decision when submitting without --outcome"
    );
    Ok(())
}
