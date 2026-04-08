#![cfg(target_os = "macos")]

use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};
use tempfile::tempdir;

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}

#[test]
fn sandbox_help_lists_exec_command() -> Result<()> {
    let output = Command::new(env!("CARGO_BIN_EXE_argon"))
        .arg("sandbox")
        .arg("--help")
        .output()
        .context("failed to run argon sandbox --help")?;

    if !output.status.success() {
        anyhow::bail!(
            "argon sandbox --help failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("exec"), "sandbox help should list exec");
    Ok(())
}

#[test]
fn user_scope_config_rejects_relative_paths() -> Result<()> {
    let temp = tempdir()?;
    let output = Command::new(env!("CARGO_BIN_EXE_argon"))
        .env("XDG_CONFIG_HOME", temp.path())
        .arg("sandbox")
        .arg("config")
        .arg("add-write-root")
        .arg("--scope")
        .arg("user")
        .arg("relative/path")
        .output()
        .context("failed to run sandbox config add-write-root")?;

    assert!(
        !output.status.success(),
        "relative user config paths should be rejected"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("user sandbox config paths must be absolute"),
        "unexpected stderr: {stderr}"
    );
    Ok(())
}

#[test]
fn sandbox_exec_restricts_writes_to_allowed_roots() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let fake_home = root.join("home");
    let fake_tmp = root.join("tmp");
    let repo_root = root.join("repo");
    let session_root = root.join("session");
    let state_root = fake_home.join(".local").join("state");
    let outside_root = fake_home.join("outside");
    std::fs::create_dir_all(&fake_home)?;
    std::fs::create_dir_all(&fake_tmp)?;
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&session_root)?;
    std::fs::create_dir_all(&state_root)?;
    std::fs::create_dir_all(&outside_root)?;

    let repo_file = repo_root.join("repo.txt");
    let session_file = session_root.join("session.txt");
    let state_file = state_root.join("state.txt");
    let outside_file = outside_root.join("outside.txt");
    let script = format!(
        "touch {} && touch {} && touch {} && : > /dev/null && if touch {}; then exit 9; else exit 0; fi",
        shell_quote(&repo_file),
        shell_quote(&session_file),
        shell_quote(&state_file),
        shell_quote(&outside_file)
    );

    let output = Command::new(env!("CARGO_BIN_EXE_argon"))
        .env("HOME", &fake_home)
        .env("TMPDIR", &fake_tmp)
        .arg("sandbox")
        .arg("exec")
        .arg("--repo-root")
        .arg(&repo_root)
        .arg("--write-root")
        .arg(&repo_root)
        .arg("--write-root")
        .arg(&session_root)
        .arg("--")
        .arg("/bin/sh")
        .arg("-c")
        .arg(&script)
        .output()
        .context("failed to run sandbox helper")?;

    if !output.status.success() {
        anyhow::bail!(
            "sandbox exec failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    assert!(repo_file.exists(), "repo root should remain writable");
    assert!(session_file.exists(), "session dir should remain writable");
    assert!(
        state_file.exists(),
        "default state dir should remain writable"
    );
    assert!(
        !outside_file.exists(),
        "writes outside the allow-list should be denied"
    );
    Ok(())
}
