#![cfg(target_os = "macos")]

use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use tempfile::tempdir;

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}

fn run_argon(command: &mut Command) -> Result<Output> {
    command.output().context("failed to run argon")
}

fn start_http_server(body: &'static str) -> Result<(u16, thread::JoinHandle<()>)> {
    let listener = TcpListener::bind("127.0.0.1:0").context("failed to bind test HTTP server")?;
    listener
        .set_nonblocking(true)
        .context("failed to mark test HTTP server nonblocking")?;
    let port = listener
        .local_addr()
        .context("failed to read HTTP server address")?
        .port();
    let handle = thread::spawn(move || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(2)));
                    let mut buffer = [0u8; 4096];
                    let _ = stream.read(&mut buffer);
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = stream.write_all(response.as_bytes());
                    let _ = stream.flush();
                    break;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if std::time::Instant::now() >= deadline {
                        break;
                    }
                    thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(_) => break,
            }
        }
    });
    Ok((port, handle))
}

#[test]
fn sandbox_help_lists_new_commands() -> Result<()> {
    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .arg("sandbox")
            .arg("--help"),
    )?;

    if !output.status.success() {
        bail!(
            "argon sandbox --help failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("init"));
    assert!(stdout.contains("builtin"));
    assert!(stdout.contains("check"));
    assert!(stdout.contains("explain"));
    assert!(stdout.contains("exec"));
    Ok(())
}

#[test]
fn sandbox_config_paths_reports_sandboxfile_locations() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("config")
            .arg("paths")
            .arg("--json"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox config paths failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Sandboxfile"));
    assert!(stdout.contains(".Sandboxfile"));
    Ok(())
}

#[test]
fn sandbox_config_paths_reports_compatibility_user_file_when_present() -> Result<()> {
    let temp = tempdir()?;
    let home = temp.path().join("home");
    let repo_root = home.join("repo");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(home.join(".Sanboxfile"), "VERSION 1\nFS DEFAULT NONE\n")?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("config")
            .arg("paths")
            .arg("--json"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox config paths with compatibility file failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("\"existingPaths\""));
    assert!(stdout.contains(".Sanboxfile"));
    Ok(())
}

#[test]
fn sandbox_init_creates_default_sandboxfile() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("init")
            .arg("--json"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox init failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let sandboxfile = repo_root.join("Sandboxfile");
    assert!(sandboxfile.exists());
    let contents = std::fs::read_to_string(&sandboxfile)?;
    assert!(contents.contains("# This file describes the Argon Sandbox configuration"));
    assert!(contents.contains("# Full docs: https://github.com/fiam/argon/blob/main/SANDBOX.md"));
    assert!(contents.contains("ENV DEFAULT NONE"));
    assert!(contents.contains("NET DEFAULT ALLOW"));
    assert!(contents.contains("FS ALLOW READ ."));
    assert!(contents.contains("USE os"));
    assert!(contents.contains("USE git"));
    assert!(contents.contains("USE shell"));
    assert!(contents.contains("USE agent"));
    assert!(contents.contains("IF TEST -f ./Sandboxfile.local"));
    assert!(contents.contains("USE ./Sandboxfile.local"));
    Ok(())
}

#[test]
fn sandbox_builtin_print_shell_warns_when_unknown() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/tcsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("builtin")
            .arg("print")
            .arg("shell")
            .arg("--json"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox builtin print shell failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("does not recognize shell"));
    Ok(())
}

#[test]
fn sandbox_check_reports_valid_sandboxfiles() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        "FS DEFAULT NONE\nFS ALLOW WRITE .\nUSE os\n",
    )?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("check"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox check failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Sandbox: valid"));
    assert!(stdout.contains("Parsed Sandboxfiles:"));
    assert!(stdout.contains("Sources:"));
    Ok(())
}

#[test]
fn sandbox_check_reports_invalid_paths_with_line_numbers() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        "FS ALLOW READ ./missing-dir/\n",
    )?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("check"),
    )?;

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("invalid path"));
    assert!(stderr.contains("Sandboxfile:1"));
    assert!(stderr.contains("IF TEST -d"));
    Ok(())
}

#[test]
fn sandbox_check_rejects_bare_net_connect_star() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(repo_root.join("Sandboxfile"), "NET ALLOW CONNECT *\n")?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("check"),
    )?;

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("NET ALLOW CONNECT `*` is invalid"));
    assert!(stderr.contains("Sandboxfile:1"));
    Ok(())
}

#[test]
fn sandbox_explain_reports_env_policy() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
VERSION 1
FS DEFAULT NONE
EXEC DEFAULT ALLOW
FS ALLOW WRITE .
USE os
ENV DEFAULT NONE
ENV ALLOW HOME
ENV SET FOO sandboxed
"#,
    )?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("explain")
            .arg("--json"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox explain failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("\"environmentDefault\": \"none\""));
    assert!(stdout.contains("\"netDefault\": \"none\""));
    assert!(stdout.contains("\"protectedSandboxFiles\""));
    assert!(stdout.contains("\"allowedEnvironmentPatterns\""));
    assert!(stdout.contains("\"FOO\": \"sandboxed\""));
    Ok(())
}

#[test]
fn sandbox_explain_reports_network_policy() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
NET DEFAULT NONE
NET ALLOW PROXY api.openai.com
NET ALLOW CONNECT 127.0.0.1:3000
NET ALLOW CONNECT udp *:53
"#,
    )?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("explain"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox explain failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Network:"));
    assert!(stdout.contains("- default: None"));
    assert!(stdout.contains("- proxy:"));
    assert!(stdout.contains("api.openai.com"));
    assert!(stdout.contains("- connect:"));
    assert!(stdout.contains("tcp 127.0.0.1:3000"));
    assert!(stdout.contains("udp *:53"));
    Ok(())
}

#[test]
fn sandbox_seatbelt_prints_raw_profile() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
FS ALLOW READ .
EXEC ALLOW /bin/cat
USE os
"#,
    )?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("seatbelt")
            .arg("--json"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox seatbelt failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("\"profile\""));
    assert!(stdout.contains("(deny default)"));
    assert!(stdout.contains("(import \\\"system.sb\\\")"));
    assert!(stdout.contains("\"parameters\""));
    Ok(())
}

#[test]
fn sandbox_explain_lists_detailed_policy_sections() -> Result<()> {
    let temp = tempdir()?;
    let home = temp.path().join("home");
    let repo_root = home.join("repo");
    std::fs::create_dir_all(repo_root.join(".argon/sandbox/intercepts"))?;
    std::fs::create_dir_all(repo_root.join(".direnv"))?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(repo_root.join("README.md"), "docs\n")?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
FS DEFAULT NONE
EXEC DEFAULT DENY
FS ALLOW READ README.md
FS ALLOW WRITE .
EXEC ALLOW /bin/echo
EXEC INTERCEPT echo WITH .argon/sandbox/intercepts/echo.sh
ENV DEFAULT NONE
ENV ALLOW HOME
ENV SET FOO sandboxed
ENV UNSET BAR
USE os
IF TEST -f ./Sandboxfile.local
    USE ./Sandboxfile.local
END
"#,
    )?;
    std::fs::write(
        repo_root.join("Sandboxfile.local"),
        "FS ALLOW WRITE .direnv\n",
    )?;
    std::fs::write(
        repo_root.join(".argon/sandbox/intercepts/echo.sh"),
        "#!/bin/sh\nexec \"$ARGON_EXEC\" \"$@\"\n",
    )?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .env("BAR", "remove-me")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("explain"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox explain failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Parsed Sandboxfiles:"));
    assert!(stdout.contains("Sources:"));
    assert!(stdout.contains("Protected Sandboxfiles:"));
    assert!(stdout.contains("Filesystem:"));
    assert!(stdout.contains("Exec:"));
    assert!(stdout.contains("Network:"));
    assert!(stdout.contains("Environment:"));
    assert!(stdout.contains("config:"));
    assert!(stdout.contains("builtin: os"));
    assert!(stdout.contains("README.md"));
    assert!(stdout.contains(".direnv"));
    assert!(stdout.contains("[read]"));
    assert!(stdout.contains("[read, write]"));
    assert!(stdout.contains("/bin/echo"));
    assert!(stdout.contains("Intercepts:"));
    assert!(stdout.contains("handler:"));
    assert!(stdout.contains("handler kind:"));
    assert!(stdout.contains("handler write protected: true"));
    assert!(stdout.contains("exec helper:"));
    assert!(stdout.contains("info helper:"));
    assert!(stdout.contains("FOO=sandboxed"));
    assert!(stdout.contains("allow:"));
    assert!(stdout.contains("unset:"));
    Ok(())
}

#[test]
fn sandbox_seatbelt_prints_network_connect_parameters() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
NET DEFAULT NONE
NET ALLOW CONNECT 127.0.0.1:3000
NET ALLOW CONNECT udp *:53
"#,
    )?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("seatbelt")
            .arg("--json"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox seatbelt failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("(remote tcp \\\"localhost:3000\\\")"));
    assert!(stdout.contains("(remote udp \\\"*:53\\\")"));
    Ok(())
}

#[test]
fn sandbox_exec_restricts_writes_to_repo_and_extra_roots() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let fake_home = root.join("home");
    let fake_tmp = root.join("sandbox-tmp");
    let repo_root = root.join("repo");
    let session_root = root.join("session");
    let outside_root = root.join("outside");
    std::fs::create_dir_all(&fake_home)?;
    std::fs::create_dir_all(&fake_tmp)?;
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&session_root)?;
    std::fs::create_dir_all(&outside_root)?;

    let repo_file = repo_root.join("repo.txt");
    let session_file = session_root.join("session.txt");
    let outside_file = outside_root.join("outside.txt");
    let script = format!(
        "touch {} && touch {} && if touch {}; then exit 9; else exit 0; fi",
        shell_quote(&repo_file),
        shell_quote(&session_file),
        shell_quote(&outside_file),
    );

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &fake_home)
            .env("TMPDIR", &fake_tmp)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--repo-root")
            .arg(&repo_root)
            .arg("--write-root")
            .arg(&session_root)
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg(&script),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox exec failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    assert!(repo_file.exists());
    assert!(session_file.exists());
    assert!(!outside_file.exists());
    Ok(())
}

#[test]
fn sandbox_exec_denies_writing_loaded_sandboxfiles() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let home = root.join("home");
    let repo_root = root.join("repo");
    std::fs::create_dir_all(&home)?;
    std::fs::create_dir_all(&repo_root)?;
    let sandboxfile = repo_root.join("Sandboxfile");
    let local_sandboxfile = repo_root.join("Sandboxfile.local");
    std::fs::write(
        &sandboxfile,
        r#"
FS DEFAULT NONE
EXEC DEFAULT ALLOW
FS ALLOW WRITE .
USE os
USE ./Sandboxfile.local
"#,
    )?;
    std::fs::write(&local_sandboxfile, "FS ALLOW WRITE .\n")?;
    let sandboxfile_before = std::fs::read_to_string(&sandboxfile)?;
    let local_sandboxfile_before = std::fs::read_to_string(&local_sandboxfile)?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg(
                "if printf bad > Sandboxfile; then exit 9; fi; \
                 if rm Sandboxfile; then exit 10; fi; \
                 if printf bad > Sandboxfile.local; then exit 11; fi; \
                 if mv Sandboxfile.local Sandboxfile.local.moved; then exit 12; fi",
            ),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox exec Sandboxfile protection failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }
    assert_eq!(std::fs::read_to_string(&sandboxfile)?, sandboxfile_before);
    assert_eq!(
        std::fs::read_to_string(&local_sandboxfile)?,
        local_sandboxfile_before
    );
    assert!(!repo_root.join("Sandboxfile.local.moved").exists());
    Ok(())
}

#[test]
fn sandbox_exec_respects_environment_allowlist_mode() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
VERSION 1
FS DEFAULT NONE
EXEC DEFAULT ALLOW
FS ALLOW WRITE .
USE os
ENV DEFAULT NONE
ENV ALLOW HOME
ENV ALLOW EXTRA_*
ENV SET FOO sandboxed
ENV UNSET PATH
"#,
    )?;

    let script = "test \"$HOME\" != \"\" && test \"$FOO\" = sandboxed && test \"$EXTRA_VISIBLE\" = inherited && test -z \"$SECRET_TOKEN\"";
    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("PATH", "/usr/bin:/bin")
            .env("EXTRA_VISIBLE", "inherited")
            .env("SECRET_TOKEN", "present-before-sandbox")
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg(script),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox exec env test failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    Ok(())
}

#[test]
fn sandbox_exec_blocks_reads_outside_repo_and_os_roots() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let repo_root = root.join("repo");
    let home = root.join("home");
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system time should be after unix epoch")?
        .as_nanos();
    let real_home = PathBuf::from(std::env::var("HOME").context("HOME should be set for tests")?);
    let outside_file = real_home.join(format!(".argon-sandbox-read-test-{stamp}.txt"));
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;

    let repo_file = repo_root.join("repo.txt");
    std::fs::write(&repo_file, "repo\n")?;
    std::fs::write(&outside_file, "outside\n")?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
FS ALLOW READ .
USE os
"#,
    )?;

    let allowed = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("PATH", "/usr/bin:/bin")
            .env("SHELL", "/bin/zsh")
            .env_remove("TMPDIR")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--")
            .arg("/bin/cat")
            .arg(&repo_file),
    )?;

    if !allowed.status.success() {
        bail!(
            "sandbox exec allowed read failed (exit {:?}):\nstdout: {}\nstderr: {}",
            allowed.status.code(),
            String::from_utf8_lossy(&allowed.stdout),
            String::from_utf8_lossy(&allowed.stderr),
        );
    }

    let denied = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("PATH", "/usr/bin:/bin")
            .env("SHELL", "/bin/zsh")
            .env_remove("TMPDIR")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--")
            .arg("/bin/cat")
            .arg(&outside_file),
    )?;

    assert!(
        !denied.status.success(),
        "unexpected success: status={:?}\nstdout:{}\nstderr:{}",
        denied.status.code(),
        String::from_utf8_lossy(&denied.stdout),
        String::from_utf8_lossy(&denied.stderr),
    );
    let stderr = String::from_utf8_lossy(&denied.stderr);
    assert!(stderr.contains("Operation not permitted"));
    std::fs::remove_file(&outside_file)?;

    Ok(())
}

#[test]
fn sandbox_exec_allows_direct_connect_rules() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    let (port, server) = start_http_server("direct-ok\n")?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        format!(
            "ENV DEFAULT NONE\nFS DEFAULT NONE\nEXEC DEFAULT ALLOW\nNET DEFAULT NONE\nNET ALLOW CONNECT 127.0.0.1:{port}\nUSE os\n"
        ),
    )?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--")
            .arg("/usr/bin/curl")
            .arg("-qfsS")
            .arg("--max-time")
            .arg("5")
            .arg(format!("http://127.0.0.1:{port}/")),
    )?;
    let _ = server.join();

    if !output.status.success() {
        bail!(
            "sandbox exec direct connect failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("direct-ok"));
    Ok(())
}

#[test]
fn sandbox_exec_routes_proxy_rules_through_local_helper() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    let (port, server) = start_http_server("proxy-ok\n")?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
ENV DEFAULT NONE
FS DEFAULT NONE
EXEC DEFAULT ALLOW
NET DEFAULT NONE
NET ALLOW PROXY *
USE os
"#,
    )?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--")
            .arg("/usr/bin/curl")
            .arg("-qfsS")
            .arg("--max-time")
            .arg("5")
            .arg(format!("http://127.0.0.1:{port}/")),
    )?;
    let _ = server.join();

    if !output.status.success() {
        bail!(
            "sandbox exec proxy connect failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("proxy-ok"));
    Ok(())
}

#[test]
fn sandbox_exec_records_proxied_requests_by_tab_id() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    let tmpdir = temp.path().join("tmp");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::create_dir_all(&tmpdir)?;
    let (port, server) = start_http_server("network-log-ok\n")?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
ENV DEFAULT NONE
FS DEFAULT NONE
EXEC DEFAULT ALLOW
NET DEFAULT NONE
NET ALLOW PROXY *
USE os
"#,
    )?;

    let tab_id = "3c270c64-3553-4e21-b0db-8ef874bf7eb5";
    let log_path = tmpdir
        .join("argon-sandbox-network")
        .join(format!("{tab_id}.ndjson"));

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("TMPDIR", &tmpdir)
            .env("SHELL", "/bin/zsh")
            .env("ARGON_TERMINAL_TAB_ID", tab_id)
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--")
            .arg("/bin/sh")
            .arg("-lc")
            .arg(format!(
                "exec /usr/bin/curl -qfsS --proxy \"$http_proxy\" --max-time 5 http://127.0.0.1:{port}/hello"
            )),
    )?;
    let _ = server.join();

    if !output.status.success() {
        bail!(
            "sandbox exec proxy logging failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let contents = std::fs::read_to_string(&log_path)
        .with_context(|| format!("missing {}", log_path.display()))?;
    assert!(contents.contains("\"kind\":\"http\""));
    assert!(contents.contains("\"outcome\":\"proxied\""));
    assert!(contents.contains("\"method\":\"GET\""));
    assert!(contents.contains("\"host\":\"127.0.0.1\""));
    assert!(contents.contains(&format!("\"port\":{port}")));
    assert!(contents.contains("\"path\":\"/hello\""));
    assert!(contents.contains("\"bytes_up\":"));
    assert!(contents.contains("\"bytes_down\":"));
    Ok(())
}

#[test]
fn sandbox_exec_does_not_force_proxy_when_network_default_is_allow() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    let tmpdir = temp.path().join("tmp");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::create_dir_all(&tmpdir)?;
    let (port, server) = start_http_server("network-default-allow\n")?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
ENV DEFAULT NONE
FS DEFAULT NONE
EXEC DEFAULT ALLOW
NET DEFAULT ALLOW
NET ALLOW PROXY *
USE os
"#,
    )?;

    let tab_id = "1cbab8e9-616f-48be-af7f-c47b0e099e40";
    let log_path = tmpdir
        .join("argon-sandbox-network")
        .join(format!("{tab_id}.ndjson"));

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("TMPDIR", &tmpdir)
            .env("SHELL", "/bin/zsh")
            .env("ARGON_TERMINAL_TAB_ID", tab_id)
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--")
            .arg("/usr/bin/curl")
            .arg("-qfsS")
            .arg("--max-time")
            .arg("5")
            .arg(format!("http://127.0.0.1:{port}/open")),
    )?;
    let _ = server.join();

    if !output.status.success() {
        bail!(
            "sandbox exec net default allow failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("network-default-allow"));
    let contents = std::fs::read_to_string(&log_path)
        .with_context(|| format!("missing {}", log_path.display()))?;
    assert!(
        contents.trim().is_empty(),
        "unexpected proxy log contents: {contents}"
    );
    Ok(())
}

#[test]
fn sandbox_exec_validates_write_roots_before_launch() -> Result<()> {
    let temp = tempdir()?;
    let repo_root = temp.path().join("repo");
    let home = temp.path().join("home");
    let missing_write_root = temp.path().join("missing-write-root");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::write(repo_root.join("Sandboxfile"), "FS ALLOW WRITE .\nUSE os\n")?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--write-root")
            .arg(&missing_write_root)
            .arg("--")
            .arg("/bin/echo")
            .arg("ok"),
    )?;

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("invalid --write-root"));
    assert!(stderr.contains("must already exist and be directories"));
    Ok(())
}

#[test]
fn sandbox_exec_runs_intercept_handlers_inside_the_sandbox() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let repo_root = root.join("repo");
    let home = root.join("home");
    let intercept_dir = repo_root.join(".argon/sandbox/intercepts");
    std::fs::create_dir_all(&intercept_dir)?;
    std::fs::create_dir_all(&home)?;

    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
VERSION 1
FS DEFAULT NONE
EXEC DEFAULT DENY
FS ALLOW WRITE .
USE os
EXEC INTERCEPT aws WITH .argon/sandbox/intercepts/aws.sh
"#,
    )?;

    let intercepted_file = repo_root.join("intercepted.txt");
    let exec_file = repo_root.join("exec.txt");
    let helpers_file = repo_root.join("helpers.txt");
    let args_file = repo_root.join("args.txt");
    let manifest_file = repo_root.join("manifest.txt");
    let handler_path = intercept_dir.join("aws.sh");
    std::fs::write(
        &handler_path,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"${{0##*/}}\" > {}\nprintf '%s\\n' \"$ARGON_EXEC\" > {}\nprintf '%s\\n%s\\n%s\\n' \"$ARGON_INFO\" \"$ARGON_WARN\" \"$ARGON_ERROR\" > {}\nprintf '%s %s\\n' \"$1\" \"$2\" > {}\nif [ -n \"$ARGON_SANDBOX_INTERCEPT_MANIFEST\" ] || [ -n \"$ARGON_SANDBOX_REAL_COMMAND\" ]; then printf '%s\\n' set > {}; exit 14; fi\n",
            shell_quote(&intercepted_file),
            shell_quote(&exec_file),
            shell_quote(&helpers_file),
            shell_quote(&args_file),
            shell_quote(&manifest_file),
        ),
    )?;
    let mut permissions = std::fs::metadata(&handler_path)?.permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&handler_path, permissions)?;
    std::fs::write(repo_root.join("aws"), "#!/bin/sh\nexit 99\n")?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("PATH", format!("{}:/bin:/usr/bin", repo_root.display()))
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--repo-root")
            .arg(&repo_root)
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg("aws first second"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox exec intercept test failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    assert_eq!(std::fs::read_to_string(&intercepted_file)?.trim(), "aws");
    assert!(
        std::fs::read_to_string(&exec_file)?
            .trim()
            .ends_with("argon-intercept-exec")
    );
    let helpers = std::fs::read_to_string(&helpers_file)?;
    assert!(helpers.contains("argon-intercept-info"));
    assert!(helpers.contains("argon-intercept-warn"));
    assert!(helpers.contains("argon-intercept-error"));
    assert_eq!(std::fs::read_to_string(&args_file)?.trim(), "first second");
    assert!(!manifest_file.exists());
    Ok(())
}

struct InterceptFixture {
    _temp: tempfile::TempDir,
    repo_root: PathBuf,
    home: PathBuf,
    real_bin: PathBuf,
    handler_path: PathBuf,
    real_command_path: PathBuf,
}

fn create_intercept_fixture() -> Result<InterceptFixture> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let repo_root = root.join("repo");
    let home = root.join("home");
    let real_bin = root.join("real-bin");
    let intercept_dir = repo_root.join(".argon/sandbox/intercepts");
    std::fs::create_dir_all(&intercept_dir)?;
    std::fs::create_dir_all(&home)?;
    std::fs::create_dir_all(&real_bin)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
FS DEFAULT NONE
EXEC DEFAULT DENY
FS ALLOW WRITE .
USE os
EXEC INTERCEPT aws WITH .argon/sandbox/intercepts/aws
"#,
    )?;

    let handler_path = intercept_dir.join("aws");
    std::fs::write(
        &handler_path,
        "#!/bin/sh\nprintf 'handler:%s\\n' \"$1\" > intercepted.txt\nexec \"$ARGON_EXEC\" \"$@\"\n",
    )?;
    let mut permissions = std::fs::metadata(&handler_path)?.permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&handler_path, permissions)?;

    let real_command_path = real_bin.join("aws");
    std::fs::write(
        &real_command_path,
        "#!/bin/sh\nprintf 'real:%s\\n' \"$1\"\n",
    )?;
    let mut permissions = std::fs::metadata(&real_command_path)?.permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&real_command_path, permissions)?;

    Ok(InterceptFixture {
        _temp: temp,
        repo_root,
        home,
        real_bin,
        handler_path,
        real_command_path,
    })
}

fn intercept_command_base(fixture: &InterceptFixture) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_argon"));
    command
        .env("HOME", &fixture.home)
        .env(
            "PATH",
            format!("{}:/bin:/usr/bin", fixture.real_bin.display()),
        )
        .env("SHELL", "/bin/zsh")
        .current_dir(&fixture.repo_root)
        .arg("sandbox")
        .arg("exec")
        .arg("--repo-root")
        .arg(&fixture.repo_root);
    command
}

#[test]
fn sandbox_exec_intercepts_commands_through_broker() -> Result<()> {
    let fixture = create_intercept_fixture()?;

    let output = run_argon(
        intercept_command_base(&fixture)
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg("aws first"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox exec broker intercept failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    assert_eq!(String::from_utf8_lossy(&output.stdout), "real:first\n");
    assert_eq!(
        std::fs::read_to_string(fixture.repo_root.join("intercepted.txt"))?,
        "handler:first\n"
    );
    Ok(())
}

#[test]
fn sandbox_exec_inline_interceptor_uses_helper_contract() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let repo_root = root.join("repo");
    let home = root.join("home");
    let real_bin = root.join("real-bin");
    std::fs::create_dir_all(&repo_root)?;
    std::fs::create_dir_all(&home)?;
    std::fs::create_dir_all(&real_bin)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
FS DEFAULT READWRITE
EXEC DEFAULT DENY
USE os
EXEC INTERCEPT aws WITH SCRIPT <<'ARGON'
#!/bin/sh
"$ARGON_INFO" "inline handler"
if printf bad > "$0"; then
    "$ARGON_ERROR" "inline handler was writable"
    exit $?
fi
exec "$ARGON_EXEC" "$@"
ARGON
"#,
    )?;
    let real_command_path = real_bin.join("aws");
    std::fs::write(
        &real_command_path,
        "#!/bin/sh\nprintf 'inline-real:%s\\n' \"$1\"\n",
    )?;
    let mut permissions = std::fs::metadata(&real_command_path)?.permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&real_command_path, permissions)?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("PATH", format!("{}:/bin:/usr/bin", real_bin.display()))
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--repo-root")
            .arg(&repo_root)
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg("aws first"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox exec inline intercept failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "inline-real:first\n"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("argon intercept info: inline handler"));
    Ok(())
}

#[test]
fn sandbox_exec_intercept_error_helper_reports_and_returns_failure() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let repo_root = root.join("repo");
    let home = root.join("home");
    let real_bin = root.join("real-bin");
    let intercept_dir = repo_root.join(".argon/sandbox/intercepts");
    std::fs::create_dir_all(&intercept_dir)?;
    std::fs::create_dir_all(&home)?;
    std::fs::create_dir_all(&real_bin)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
FS DEFAULT NONE
EXEC DEFAULT DENY
FS ALLOW READ .
USE os
EXEC INTERCEPT aws WITH .argon/sandbox/intercepts/aws
"#,
    )?;
    let handler_path = intercept_dir.join("aws");
    std::fs::write(
        &handler_path,
        "#!/bin/sh\n\"$ARGON_INFO\" \"checking\"\n\"$ARGON_WARN\" \"careful\"\n\"$ARGON_ERROR\" \"denied\"\nexit $?\n",
    )?;
    let mut permissions = std::fs::metadata(&handler_path)?.permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&handler_path, permissions)?;
    let real_command_path = real_bin.join("aws");
    std::fs::write(&real_command_path, "#!/bin/sh\nexit 0\n")?;
    let mut permissions = std::fs::metadata(&real_command_path)?.permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&real_command_path, permissions)?;

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("PATH", format!("{}:/bin:/usr/bin", real_bin.display()))
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--repo-root")
            .arg(&repo_root)
            .arg("--")
            .arg("aws"),
    )?;

    assert!(
        !output.status.success(),
        "intercept error unexpectedly succeeded:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(output.status.code(), Some(126));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("argon intercept info: checking"));
    assert!(stderr.contains("argon intercept warning: careful"));
    assert!(stderr.contains("argon intercept error: denied"));
    Ok(())
}

#[test]
fn sandbox_exec_argon_exec_is_command_specific() -> Result<()> {
    let temp = tempdir()?;
    let root = temp.path().canonicalize()?;
    let repo_root = root.join("repo");
    let home = root.join("home");
    let real_bin = root.join("real-bin");
    let intercept_dir = repo_root.join(".argon/sandbox/intercepts");
    std::fs::create_dir_all(&intercept_dir)?;
    std::fs::create_dir_all(&home)?;
    std::fs::create_dir_all(&real_bin)?;
    std::fs::write(
        repo_root.join("Sandboxfile"),
        r#"
FS DEFAULT NONE
EXEC DEFAULT DENY
FS ALLOW READ .
USE os
EXEC INTERCEPT aws WITH .argon/sandbox/intercepts/aws
EXEC INTERCEPT gh WITH .argon/sandbox/intercepts/gh
"#,
    )?;
    for name in ["aws", "gh"] {
        let handler_path = intercept_dir.join(name);
        std::fs::write(&handler_path, "#!/bin/sh\nexec \"$ARGON_EXEC\" \"$@\"\n")?;
        let mut permissions = std::fs::metadata(&handler_path)?.permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&handler_path, permissions)?;

        let real_command_path = real_bin.join(name);
        std::fs::write(
            &real_command_path,
            format!("#!/bin/sh\nprintf '{name}:%s\\n' \"$1\"\n"),
        )?;
        let mut permissions = std::fs::metadata(&real_command_path)?.permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&real_command_path, permissions)?;
    }

    let output = run_argon(
        Command::new(env!("CARGO_BIN_EXE_argon"))
            .env("HOME", &home)
            .env("PATH", format!("{}:/bin:/usr/bin", real_bin.display()))
            .env("SHELL", "/bin/zsh")
            .current_dir(&repo_root)
            .arg("sandbox")
            .arg("exec")
            .arg("--repo-root")
            .arg(&repo_root)
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg("aws first && gh second"),
    )?;

    if !output.status.success() {
        bail!(
            "sandbox exec multi-intercept failed (exit {:?}):\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "aws:first\ngh:second\n"
    );
    Ok(())
}

#[test]
fn sandbox_exec_denies_direct_real_intercept_command_execution() -> Result<()> {
    let fixture = create_intercept_fixture()?;

    let output = run_argon(
        intercept_command_base(&fixture)
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg(shell_quote(&fixture.real_command_path)),
    )?;

    assert!(
        !output.status.success(),
        "direct real command unexpectedly succeeded:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(())
}

#[test]
fn sandbox_exec_denies_reading_real_intercept_command() -> Result<()> {
    let fixture = create_intercept_fixture()?;

    let output = run_argon(
        intercept_command_base(&fixture)
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg(format!("cat {}", shell_quote(&fixture.real_command_path))),
    )?;

    assert!(
        !output.status.success(),
        "reading real command unexpectedly succeeded:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(())
}

#[test]
fn sandbox_exec_denies_writing_repo_interceptor() -> Result<()> {
    let fixture = create_intercept_fixture()?;
    let original = std::fs::read_to_string(&fixture.handler_path)?;

    let output = run_argon(
        intercept_command_base(&fixture)
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg("printf bad > .argon/sandbox/intercepts/aws"),
    )?;

    assert!(
        !output.status.success(),
        "writing interceptor unexpectedly succeeded:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(std::fs::read_to_string(&fixture.handler_path)?, original);
    Ok(())
}
