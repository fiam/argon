#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use tempfile::Builder as TempDirBuilder;

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}

fn argon_terminal_attach(session_id: &str, storage_dir: &Path, command: &str) -> Result<Command> {
    argon_terminal_attach_with_flags(session_id, storage_dir, &[], command)
}

fn argon_terminal_attach_with_flags(
    session_id: &str,
    storage_dir: &Path,
    flags: &[&str],
    command: &str,
) -> Result<Command> {
    let mut process = Command::new(env!("CARGO_BIN_EXE_argon"));
    process
        .arg("terminal")
        .arg("attach")
        .arg("--session-id")
        .arg(session_id)
        .arg("--storage-dir")
        .arg(storage_dir);
    process.args(flags);
    process.arg("--").arg("/bin/sh").arg("-lc").arg(command);
    Ok(process)
}

fn argon_terminal_status(session_id: &str, storage_dir: &Path) -> Result<serde_json::Value> {
    let output = Command::new(env!("CARGO_BIN_EXE_argon"))
        .arg("terminal")
        .arg("status")
        .arg("--session-id")
        .arg(session_id)
        .arg("--storage-dir")
        .arg(storage_dir)
        .arg("--json")
        .output()
        .context("failed to run terminal status")?;
    if !output.status.success() {
        bail!(
            "terminal status failed (exit {:?})\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    serde_json::from_slice(&output.stdout).context("failed to parse terminal status JSON")
}

fn argon_terminal_stop(session_id: &str, storage_dir: &Path) -> Result<()> {
    let output = Command::new(env!("CARGO_BIN_EXE_argon"))
        .arg("terminal")
        .arg("stop")
        .arg("--session-id")
        .arg(session_id)
        .arg("--storage-dir")
        .arg(storage_dir)
        .output()
        .context("failed to run terminal stop")?;
    if !output.status.success() {
        bail!(
            "terminal stop failed (exit {:?})\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

fn wait_for_file_contents_or_child_exit(
    mut child: Child,
    path: &Path,
    expected: &str,
    process_needle: &str,
    timeout: Duration,
) -> Result<Child> {
    let deadline = Instant::now() + timeout;
    let mut last_contents = String::new();
    loop {
        match fs::read_to_string(path) {
            Ok(contents) => {
                if contents == expected {
                    return Ok(child);
                }
                last_contents = contents;
            }
            Err(_) => {}
        }

        if child.try_wait()?.is_some() {
            let output = child
                .wait_with_output()
                .context("failed to collect early terminal attach output")?;
            bail!(
                "terminal attach exited with {:?} before {} contained {:?}\nstdout: {}\nstderr: {}",
                output.status.code(),
                path.display(),
                expected,
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }

        if Instant::now() >= deadline {
            let processes = process_snapshot(process_needle);
            let _ = child.kill();
            let output = child
                .wait_with_output()
                .context("failed to collect timed-out terminal attach output")?;
            bail!(
                "timed out waiting for {} to contain {:?}; last contents were {:?}\nstdout: {}\nstderr: {}\nprocesses:\n{}",
                path.display(),
                expected,
                last_contents,
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr),
                processes
            );
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn process_snapshot(needle: &str) -> String {
    let output = Command::new("ps")
        .arg("-axo")
        .arg("pid,ppid,stat,command")
        .output();
    let Ok(output) = output else {
        return "failed to run ps".to_string();
    };
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| line.contains(needle))
        .collect::<Vec<_>>()
        .join("\n")
}

fn wait_with_output_timeout(mut child: Child, timeout: Duration) -> Result<Output> {
    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait()?.is_some() {
            return child
                .wait_with_output()
                .context("failed to collect terminal attach output");
        }

        if Instant::now() >= deadline {
            let _ = child.kill();
            let output = child
                .wait_with_output()
                .context("failed to collect timed-out terminal attach output")?;
            bail!(
                "terminal attach timed out\nstdout: {}\nstderr: {}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_file_contents(path: &Path, expected: &str, timeout: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    let mut last_contents = String::new();
    loop {
        match fs::read_to_string(path) {
            Ok(contents) => {
                if contents == expected {
                    return Ok(());
                }
                last_contents = contents;
            }
            Err(_) => {}
        }

        if Instant::now() >= deadline {
            bail!(
                "timed out waiting for {} to contain {:?}; last contents were {:?}",
                path.display(),
                expected,
                last_contents
            );
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_terminal_status(
    session_id: &str,
    storage_dir: &Path,
    expected_running: bool,
    timeout: Duration,
) -> Result<serde_json::Value> {
    let deadline = Instant::now() + timeout;
    loop {
        let status = argon_terminal_status(session_id, storage_dir)?;
        if status["server_running"] == expected_running {
            return Ok(status);
        }

        if Instant::now() >= deadline {
            bail!(
                "timed out waiting for terminal status server_running={expected_running}; last status was {}",
                status
            );
        }
        thread::sleep(Duration::from_millis(25));
    }
}

struct TerminalSessionCleanup {
    session_id: String,
    storage_dir: PathBuf,
}

impl Drop for TerminalSessionCleanup {
    fn drop(&mut self) {
        let _ = Command::new(env!("CARGO_BIN_EXE_argon"))
            .arg("terminal")
            .arg("stop")
            .arg("--session-id")
            .arg(&self.session_id)
            .arg("--storage-dir")
            .arg(&self.storage_dir)
            .status();
    }
}

#[test]
fn terminal_session_status_reports_running_server() -> Result<()> {
    let temp = TempDirBuilder::new()
        .prefix("argon-ts-status")
        .tempdir_in("/tmp")?;
    let storage_dir = temp.path().join("s");
    let marker = temp.path().join("marker");
    let process_needle = storage_dir.display().to_string();
    let session_id = "status";
    let _cleanup = TerminalSessionCleanup {
        session_id: session_id.to_string(),
        storage_dir: storage_dir.clone(),
    };

    let command = format!("printf started > {}; sleep 30", shell_quote(&marker));
    let attach = argon_terminal_attach(session_id, &storage_dir, &command)?
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start status terminal attach")?;
    let attach = wait_for_file_contents_or_child_exit(
        attach,
        &marker,
        "started",
        &process_needle,
        Duration::from_secs(5),
    )?;

    let status = wait_for_terminal_status(session_id, &storage_dir, true, Duration::from_secs(5))?;
    assert_eq!(status["session_id"], session_id);
    assert_eq!(status["socket_exists"], true);
    assert!(status["pid"].is_number(), "status was {status}");

    argon_terminal_stop(session_id, &storage_dir)?;
    let stopped_status =
        wait_for_terminal_status(session_id, &storage_dir, false, Duration::from_secs(5))?;
    assert_eq!(stopped_status["socket_exists"], false);

    let _ = wait_with_output_timeout(attach, Duration::from_secs(5))?;

    Ok(())
}

#[test]
fn terminal_session_survives_attach_detach_and_reattach() -> Result<()> {
    let temp = TempDirBuilder::new()
        .prefix("argon-ts")
        .tempdir_in("/tmp")?;
    let storage_dir = temp.path().join("s");
    let marker = temp.path().join("marker");
    let process_needle = storage_dir.display().to_string();
    let session_id = "sleep";
    let _cleanup = TerminalSessionCleanup {
        session_id: session_id.to_string(),
        storage_dir: storage_dir.clone(),
    };

    let first_command = format!(
        "printf 'started\\n'; printf started > {}; sleep 2; printf done > {}; printf 'done\\n'",
        shell_quote(&marker),
        shell_quote(&marker)
    );
    let first_attach = argon_terminal_attach(session_id, &storage_dir, &first_command)?
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start first terminal attach")?;

    let mut first_attach = wait_for_file_contents_or_child_exit(
        first_attach,
        &marker,
        "started",
        &process_needle,
        Duration::from_secs(5),
    )?;
    if first_attach.try_wait()?.is_some() {
        let output = first_attach
            .wait_with_output()
            .context("failed to collect early first attach output")?;
        bail!(
            "first terminal attach exited before detach\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    first_attach
        .kill()
        .context("failed to detach first terminal attach")?;
    let _ = first_attach.wait();

    let second_command = format!("printf replacement > {}", shell_quote(&marker));
    let second_attach = argon_terminal_attach(session_id, &storage_dir, &second_command)?
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start second terminal attach")?;
    let output = wait_with_output_timeout(second_attach, Duration::from_secs(6))?;

    if !output.status.success() {
        bail!(
            "second terminal attach failed (exit {:?})\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("started"),
        "reattach should replay prior terminal output; stdout was {stdout:?}"
    );
    assert!(
        stdout.contains("done"),
        "reattach should stream output until the original command exits; stdout was {stdout:?}"
    );
    assert_eq!(fs::read_to_string(&marker)?, "done");

    Ok(())
}

#[test]
fn terminal_session_keeps_existing_client_when_another_client_attaches() -> Result<()> {
    let temp = TempDirBuilder::new()
        .prefix("argon-ts-multi-client")
        .tempdir_in("/tmp")?;
    let storage_dir = temp.path().join("s");
    let marker = temp.path().join("marker");
    let process_needle = storage_dir.display().to_string();
    let session_id = "multi-client";
    let _cleanup = TerminalSessionCleanup {
        session_id: session_id.to_string(),
        storage_dir: storage_dir.clone(),
    };

    let command = format!("printf started > {}; sleep 30", shell_quote(&marker));
    let first_attach = argon_terminal_attach(session_id, &storage_dir, &command)?
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start first multi-client terminal attach")?;
    let mut first_attach = wait_for_file_contents_or_child_exit(
        first_attach,
        &marker,
        "started",
        &process_needle,
        Duration::from_secs(5),
    )?;

    let mut second_attach = argon_terminal_attach_with_flags(
        session_id,
        &storage_dir,
        &["--no-replay"],
        "printf replacement",
    )?
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .context("failed to start second multi-client terminal attach")?;

    thread::sleep(Duration::from_millis(500));
    if first_attach.try_wait()?.is_some() {
        let output = first_attach
            .wait_with_output()
            .context("failed to collect displaced first attach output")?;
        bail!(
            "first terminal attach exited after second attach connected\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    if second_attach.try_wait()?.is_some() {
        let output = second_attach
            .wait_with_output()
            .context("failed to collect early second attach output")?;
        bail!(
            "second terminal attach exited while child was still running\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    second_attach
        .kill()
        .context("failed to detach second multi-client terminal attach")?;
    let _ = second_attach.wait();
    thread::sleep(Duration::from_millis(250));
    if first_attach.try_wait()?.is_some() {
        let output = first_attach
            .wait_with_output()
            .context("failed to collect first attach output after second detach")?;
        bail!(
            "first terminal attach exited after second attach detached\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    argon_terminal_stop(session_id, &storage_dir)?;
    let _ = wait_with_output_timeout(first_attach, Duration::from_secs(5))?;

    Ok(())
}

#[test]
fn terminal_session_can_reattach_without_replaying_buffered_output() -> Result<()> {
    let temp = TempDirBuilder::new()
        .prefix("argon-ts-no-replay")
        .tempdir_in("/tmp")?;
    let storage_dir = temp.path().join("s");
    let marker = temp.path().join("marker");
    let process_needle = storage_dir.display().to_string();
    let session_id = "sleep-no-replay";
    let _cleanup = TerminalSessionCleanup {
        session_id: session_id.to_string(),
        storage_dir: storage_dir.clone(),
    };

    let first_command = format!(
        "printf 'started\\n'; printf started > {}; sleep 2; printf done > {}; printf 'done\\n'",
        shell_quote(&marker),
        shell_quote(&marker)
    );
    let first_attach = argon_terminal_attach(session_id, &storage_dir, &first_command)?
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start first no-replay terminal attach")?;

    let mut first_attach = wait_for_file_contents_or_child_exit(
        first_attach,
        &marker,
        "started",
        &process_needle,
        Duration::from_secs(5),
    )?;
    first_attach
        .kill()
        .context("failed to detach first no-replay terminal attach")?;
    let _ = first_attach.wait();

    let second_command = format!("printf replacement > {}", shell_quote(&marker));
    let second_attach = argon_terminal_attach_with_flags(
        session_id,
        &storage_dir,
        &["--no-replay"],
        &second_command,
    )?
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .context("failed to start second no-replay terminal attach")?;
    let output = wait_with_output_timeout(second_attach, Duration::from_secs(6))?;

    if !output.status.success() {
        bail!(
            "second no-replay terminal attach failed (exit {:?})\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("\x1b[2J"),
        "reattach with --no-replay should clear the local terminal; stdout was {stdout:?}"
    );
    assert!(
        !stdout.contains("started"),
        "reattach with --no-replay should not replay prior output; stdout was {stdout:?}"
    );
    assert!(
        stdout.contains("done"),
        "reattach should still stream live output; stdout was {stdout:?}"
    );
    assert_eq!(fs::read_to_string(&marker)?, "done");

    Ok(())
}

#[test]
fn terminal_session_exits_after_detached_child_exits() -> Result<()> {
    let temp = TempDirBuilder::new()
        .prefix("argon-ts-restart-exited")
        .tempdir_in("/tmp")?;
    let storage_dir = temp.path().join("s");
    let marker = temp.path().join("marker");
    let process_needle = storage_dir.display().to_string();
    let session_id = "restart-exited";
    let _cleanup = TerminalSessionCleanup {
        session_id: session_id.to_string(),
        storage_dir: storage_dir.clone(),
    };

    let first_command = format!(
        "printf 'started\\n'; printf started > {}; sleep 1; printf done > {}; printf 'done\\n'",
        shell_quote(&marker),
        shell_quote(&marker)
    );
    let first_attach = argon_terminal_attach(session_id, &storage_dir, &first_command)?
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start first restart-exited attach")?;
    let mut first_attach = wait_for_file_contents_or_child_exit(
        first_attach,
        &marker,
        "started",
        &process_needle,
        Duration::from_secs(5),
    )?;
    first_attach
        .kill()
        .context("failed to detach first restart-exited attach")?;
    let _ = first_attach.wait();

    wait_for_file_contents(&marker, "done", Duration::from_secs(5))?;
    thread::sleep(Duration::from_millis(500));

    let second_command = format!(
        "printf replacement > {}; printf 'replacement\\n'; sleep 1",
        shell_quote(&marker)
    );
    let second_attach = argon_terminal_attach_with_flags(
        session_id,
        &storage_dir,
        &["--no-replay"],
        &second_command,
    )?
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .context("failed to start second exited-child attach")?;
    let output = wait_with_output_timeout(second_attach, Duration::from_secs(6))?;

    if !output.status.success() {
        bail!(
            "second exited-child attach failed (exit {:?})\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("replacement"),
        "reattach after child exit should run the replacement command; stdout was {stdout:?}"
    );
    assert!(
        !stdout.contains("done"),
        "restart should not replay the exited session; stdout was {stdout:?}"
    );
    assert_eq!(fs::read_to_string(&marker)?, "replacement");

    Ok(())
}
