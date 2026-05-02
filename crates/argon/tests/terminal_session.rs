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
