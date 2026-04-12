#![cfg(target_os = "macos")]

use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

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
fn user_scope_config_expands_home_shorthand() -> Result<()> {
    let temp = tempdir()?;
    let fake_home = temp.path().join("home");
    std::fs::create_dir_all(&fake_home)?;
    let output = Command::new(env!("CARGO_BIN_EXE_argon"))
        .env("HOME", &fake_home)
        .env("XDG_CONFIG_HOME", temp.path())
        .arg("sandbox")
        .arg("config")
        .arg("add-write-root")
        .arg("--scope")
        .arg("user")
        .arg("~/.claude.json.lock")
        .arg("--json")
        .output()
        .context("failed to run sandbox config add-write-root with ~ path")?;

    if !output.status.success() {
        anyhow::bail!(
            "sandbox config add-write-root with ~ failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains(&fake_home.join(".claude.json.lock").display().to_string()),
        "expected expanded home path in output: {stdout}"
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
    let claude_config_file = fake_home.join(".claude.json");
    let claude_lock_dir = fake_home.join(".claude.json.lock");
    let claude_lock_file = claude_lock_dir.join("lock.txt");
    let outside_file = outside_root.join("outside.txt");
    let script = format!(
        "touch {} && touch {} && touch {} && touch {} && mkdir -p {} && touch {} && : > /dev/null && if touch {}; then exit 9; else exit 0; fi",
        shell_quote(&repo_file),
        shell_quote(&session_file),
        shell_quote(&state_file),
        shell_quote(&claude_config_file),
        shell_quote(&claude_lock_dir),
        shell_quote(&claude_lock_file),
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
        claude_config_file.exists(),
        "Claude config file should remain writable"
    );
    assert!(
        claude_lock_file.exists(),
        "Claude config lock dir should remain writable"
    );
    assert!(
        !outside_file.exists(),
        "writes outside the allow-list should be denied"
    );
    Ok(())
}

#[test]
fn sandbox_exec_defaults_write_root_to_current_directory() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let fake_home = root.join("home");
    let fake_tmp = root.join("tmp");
    let repo_root = root.join("repo");
    let cwd_root = repo_root.join("cwd");
    let inside_file = cwd_root.join("inside.txt");
    let outside_file = repo_root.join("outside.txt");
    std::fs::create_dir_all(&fake_home)?;
    std::fs::create_dir_all(&fake_tmp)?;
    std::fs::create_dir_all(&cwd_root)?;

    let script = format!(
        "touch {} && if touch {}; then exit 9; else exit 0; fi",
        shell_quote(&inside_file),
        shell_quote(&outside_file)
    );

    let output = Command::new(env!("CARGO_BIN_EXE_argon"))
        .env("HOME", &fake_home)
        .env("TMPDIR", &fake_tmp)
        .current_dir(&cwd_root)
        .arg("sandbox")
        .arg("exec")
        .arg("--")
        .arg("/bin/sh")
        .arg("-c")
        .arg(&script)
        .output()
        .context("failed to run sandbox helper without explicit write-root")?;

    if !output.status.success() {
        anyhow::bail!(
            "sandbox exec without write-root failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    assert!(
        inside_file.exists(),
        "cwd should remain writable by default"
    );
    assert!(
        !outside_file.exists(),
        "paths outside the cwd should remain read-only by default"
    );
    Ok(())
}

#[test]
fn sandbox_exec_allows_standard_system_tmp_root() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let fake_home = root.join("home");
    let fake_tmp = root.join("tmp");
    let cwd_root = root.join("cwd");
    std::fs::create_dir_all(&fake_home)?;
    std::fs::create_dir_all(&fake_tmp)?;
    std::fs::create_dir_all(&cwd_root)?;

    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("clock went backwards")?
        .as_nanos();
    let system_tmp_root = if Path::new("/private/tmp").exists() {
        Path::new("/private/tmp")
    } else {
        Path::new("/tmp")
    };
    let temp_dir = system_tmp_root.join(format!("argon-sandbox-{stamp}"));
    let temp_file = temp_dir.join("ok.txt");
    let script = format!(
        "cleanup() {{ rm -f {file} 2>/dev/null || true; rmdir {dir} 2>/dev/null || true; }}; \
         trap cleanup EXIT; \
         mkdir -p {dir} && touch {file}",
        dir = shell_quote(&temp_dir),
        file = shell_quote(&temp_file)
    );

    let output = Command::new(env!("CARGO_BIN_EXE_argon"))
        .env("HOME", &fake_home)
        .env("TMPDIR", &fake_tmp)
        .current_dir(&cwd_root)
        .arg("sandbox")
        .arg("exec")
        .arg("--write-root")
        .arg(&cwd_root)
        .arg("--")
        .arg("/bin/sh")
        .arg("-c")
        .arg(&script)
        .output()
        .context("failed to run sandbox helper for system tmp root")?;

    let _ = std::fs::remove_dir_all(&temp_dir);

    if !output.status.success() {
        anyhow::bail!(
            "sandbox exec for system tmp root failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    assert!(
        !temp_dir.exists(),
        "temporary system tmp directory should be cleaned up"
    );
    Ok(())
}
