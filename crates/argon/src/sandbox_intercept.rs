use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BrokerConfig {
    pub parent_pid: u32,
    pub socket_path: PathBuf,
    pub token: String,
    pub current_dir: PathBuf,
    pub environment: BTreeMap<String, String>,
    pub policy: sandbox::EffectiveSandboxPolicy,
    pub intercepts: Vec<sandbox::ResolvedIntercept>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerConfig {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub current_dir: PathBuf,
    pub environment: BTreeMap<String, String>,
    pub policy: sandbox::EffectiveSandboxPolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BrokerRequest {
    token: String,
    command_name: String,
    args: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BrokerResponse {
    exit_code: Option<i32>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    error: Option<String>,
}

pub fn spawn_broker(current_exe: &Path, config: BrokerConfig, config_path: &Path) -> Result<()> {
    fs::write(
        config_path,
        serde_json::to_vec_pretty(&config)
            .context("failed to serialize intercept broker config")?,
    )
    .with_context(|| format!("failed to write {}", config_path.display()))?;

    let mut child = Command::new(current_exe)
        .arg("sandbox")
        .arg("intercept-broker")
        .arg("--config")
        .arg(config_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to launch sandbox intercept broker")?;

    let stdout = child
        .stdout
        .take()
        .context("intercept broker did not expose stdout")?;
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    let read = reader
        .read_line(&mut line)
        .context("failed to read intercept broker readiness")?;
    if read == 0 {
        let mut stderr = String::new();
        if let Some(mut pipe) = child.stderr.take() {
            let _ = pipe.read_to_string(&mut stderr);
        }
        let status = child
            .wait()
            .context("failed to wait for intercept broker")?;
        bail!("intercept broker exited before reporting readiness: {status}\n{stderr}");
    }
    if line.trim() != "ready" {
        bail!("intercept broker reported unexpected readiness line: {line:?}");
    }

    Ok(())
}

pub fn maybe_run_intercept_helper() -> Result<bool> {
    let argv0 = std::env::args()
        .next()
        .and_then(|value| {
            Path::new(&value)
                .file_name()
                .and_then(|name| name.to_str())
                .map(str::to_string)
        })
        .unwrap_or_default();
    match argv0.as_str() {
        "argon-intercept-info" => {
            run_message_helper("info", 0);
        }
        "argon-intercept-warn" => {
            run_message_helper("warning", 0);
        }
        "argon-intercept-error" => {
            run_message_helper("error", 126);
        }
        "argon-intercept-exec" => {
            run_intercept_exec_helper()?;
            Ok(true)
        }
        "argon-intercept-run" => {
            run_legacy_intercept_runner()?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

fn run_message_helper(label: &str, code: i32) -> ! {
    let message = std::env::args().skip(1).collect::<Vec<_>>().join(" ");
    if message.is_empty() {
        eprintln!("argon intercept {label}");
    } else {
        eprintln!("argon intercept {label}: {message}");
    }
    std::process::exit(code);
}

fn run_intercept_exec_helper() -> Result<()> {
    let socket_path = std::env::var_os(sandbox::INTERCEPT_SOCKET_ENV)
        .map(PathBuf::from)
        .context("missing ARGON_SANDBOX_INTERCEPT_SOCKET")?;
    let token = std::env::var(sandbox::INTERCEPT_TOKEN_ENV)
        .context("missing ARGON_SANDBOX_INTERCEPT_TOKEN")?;
    let command_name = std::env::var(sandbox::INTERCEPT_COMMAND_ENV)
        .context("missing ARGON_SANDBOX_INTERCEPT_COMMAND")?;
    if command_name.contains('/') || command_name.is_empty() {
        bail!("invalid intercepted command name: {command_name}");
    }

    let response = send_request(
        &socket_path,
        &BrokerRequest {
            token,
            command_name,
            args: std::env::args().skip(1).collect(),
        },
    )?;
    finish_broker_response(response)
}

fn run_legacy_intercept_runner() -> Result<()> {
    let socket_path = std::env::var_os(sandbox::INTERCEPT_SOCKET_ENV)
        .map(PathBuf::from)
        .context("missing ARGON_SANDBOX_INTERCEPT_SOCKET")?;
    let token = std::env::var(sandbox::INTERCEPT_TOKEN_ENV)
        .context("missing ARGON_SANDBOX_INTERCEPT_TOKEN")?;
    let mut args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.is_empty() {
        bail!("intercept runner requires the intercepted command name as argv1");
    }
    let command_name = args.remove(0);
    if command_name.contains('/') || command_name.is_empty() {
        bail!("invalid intercepted command name: {command_name}");
    }

    let response = send_request(
        &socket_path,
        &BrokerRequest {
            token,
            command_name,
            args,
        },
    )?;
    finish_broker_response(response)
}

fn finish_broker_response(response: BrokerResponse) -> Result<()> {
    std::io::stdout()
        .write_all(&response.stdout)
        .context("failed to write intercepted stdout")?;
    std::io::stderr()
        .write_all(&response.stderr)
        .context("failed to write intercepted stderr")?;
    if let Some(error) = response.error {
        bail!("{error}");
    }
    std::process::exit(response.exit_code.unwrap_or(1));
}

#[cfg(unix)]
fn send_request(socket_path: &Path, request: &BrokerRequest) -> Result<BrokerResponse> {
    let mut stream = UnixStream::connect(socket_path).with_context(|| {
        format!(
            "failed to connect to intercept broker at {}",
            socket_path.display()
        )
    })?;
    serde_json::to_writer(&mut stream, request).context("failed to write intercept request")?;
    stream
        .write_all(b"\n")
        .context("failed to terminate intercept request")?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    let read = reader
        .read_line(&mut line)
        .context("failed to read intercept response")?;
    if read == 0 {
        bail!("intercept broker closed without a response");
    }
    serde_json::from_str(&line).context("failed to parse intercept response")
}

#[cfg(not(unix))]
fn send_request(_socket_path: &Path, _request: &BrokerRequest) -> Result<BrokerResponse> {
    bail!("sandbox intercept broker is only available on Unix platforms")
}

pub fn run_broker(config_path: &Path) -> Result<()> {
    #[cfg(not(unix))]
    {
        let _ = config_path;
        bail!("sandbox intercept broker is only available on Unix platforms");
    }

    #[cfg(unix)]
    {
        let payload = fs::read_to_string(config_path)
            .with_context(|| format!("failed to read {}", config_path.display()))?;
        let config: BrokerConfig =
            serde_json::from_str(&payload).context("failed to parse intercept broker config")?;
        if config.socket_path.exists() {
            fs::remove_file(&config.socket_path).with_context(|| {
                format!(
                    "failed to remove stale intercept broker socket {}",
                    config.socket_path.display()
                )
            })?;
        }
        let listener = UnixListener::bind(&config.socket_path).with_context(|| {
            format!(
                "failed to bind intercept broker socket {}",
                config.socket_path.display()
            )
        })?;
        println!("ready");
        std::io::stdout()
            .flush()
            .context("failed to flush intercept broker readiness")?;

        spawn_parent_watchdog(config.parent_pid);
        for stream in listener.incoming() {
            let stream = match stream {
                Ok(stream) => stream,
                Err(error) => {
                    eprintln!("sandbox intercept broker accept failed: {error}");
                    continue;
                }
            };
            let config = config.clone();
            thread::spawn(move || {
                if let Err(error) = handle_client(stream, &config) {
                    eprintln!("sandbox intercept broker request failed: {error}");
                }
            });
        }
        Ok(())
    }
}

#[cfg(unix)]
fn handle_client(mut stream: UnixStream, config: &BrokerConfig) -> Result<()> {
    let request = {
        let mut reader = BufReader::new(&mut stream);
        let mut line = String::new();
        let read = reader
            .read_line(&mut line)
            .context("failed to read intercept broker request")?;
        if read == 0 {
            bail!("empty intercept broker request");
        }
        serde_json::from_str::<BrokerRequest>(&line).context("failed to parse broker request")?
    };

    let response = match execute_request(config, request) {
        Ok(response) => response,
        Err(error) => BrokerResponse {
            exit_code: Some(126),
            stdout: Vec::new(),
            stderr: Vec::new(),
            error: Some(format!("{error:#}")),
        },
    };
    serde_json::to_writer(&mut stream, &response).context("failed to write broker response")?;
    stream
        .write_all(b"\n")
        .context("failed to terminate broker response")?;
    Ok(())
}

fn execute_request(config: &BrokerConfig, request: BrokerRequest) -> Result<BrokerResponse> {
    if request.token != config.token {
        bail!("intercept broker rejected request with invalid token");
    }
    let intercept = config
        .intercepts
        .iter()
        .find(|intercept| intercept.command_name == request.command_name)
        .with_context(|| {
            format!(
                "intercept broker does not know command `{}`",
                request.command_name
            )
        })?;
    let real_command_path = intercept
        .real_command_path
        .as_ref()
        .context("intercept is missing a resolved real command")?;
    let mut environment = config.environment.clone();
    environment.remove(sandbox::INTERCEPT_RUNNER_ENV);
    environment.remove(sandbox::INTERCEPT_SOCKET_ENV);
    environment.remove(sandbox::INTERCEPT_TOKEN_ENV);
    environment.remove(sandbox::INTERCEPT_COMMAND_ENV);
    environment.remove(sandbox::ARGON_INFO_ENV);
    environment.remove(sandbox::ARGON_WARN_ENV);
    environment.remove(sandbox::ARGON_ERROR_ENV);
    environment.remove(sandbox::ARGON_EXEC_ENV);
    if let Some(path) = environment.get("ARGON_SANDBOX_ORIGINAL_PATH").cloned() {
        environment.insert("PATH".to_string(), path);
        environment.remove("ARGON_SANDBOX_ORIGINAL_PATH");
    }

    let policy = sandbox::intercept_inner_policy(&config.policy, intercept);
    let worker_config = WorkerConfig {
        program: real_command_path.clone(),
        args: request.args,
        current_dir: config.current_dir.clone(),
        environment,
        policy,
    };
    run_worker_process(config, &worker_config)
}

fn run_worker_process(
    config: &BrokerConfig,
    worker_config: &WorkerConfig,
) -> Result<BrokerResponse> {
    let worker_config_path = config.socket_path.with_extension(format!(
        "worker-{}-{}.json",
        std::process::id(),
        timestamp_nanos()
    ));
    fs::write(
        &worker_config_path,
        serde_json::to_vec(worker_config).context("failed to serialize intercept worker config")?,
    )
    .with_context(|| {
        format!(
            "failed to write intercept worker config {}",
            worker_config_path.display()
        )
    })?;

    let current_exe = std::env::current_exe().context("failed to resolve current executable")?;
    let output = Command::new(current_exe)
        .arg("sandbox")
        .arg("intercept-worker")
        .arg("--config")
        .arg(&worker_config_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("failed to run intercept worker")?;
    let _ = fs::remove_file(&worker_config_path);

    Ok(BrokerResponse {
        exit_code: output.status.code(),
        stdout: output.stdout,
        stderr: output.stderr,
        error: None,
    })
}

pub fn run_worker(config_path: &Path) -> Result<()> {
    let payload = fs::read_to_string(config_path)
        .with_context(|| format!("failed to read {}", config_path.display()))?;
    let config: WorkerConfig =
        serde_json::from_str(&payload).context("failed to parse intercept worker config")?;
    let _ = fs::remove_file(config_path);
    sandbox::apply_current_process(&config.policy)?;
    let mut command = Command::new(&config.program);
    command
        .args(&config.args)
        .current_dir(&config.current_dir)
        .env_clear()
        .envs(&config.environment);

    #[cfg(unix)]
    {
        let error = command.exec();
        Err(anyhow::Error::new(error)
            .context(format!("failed to exec {}", config.program.display())))
    }

    #[cfg(not(unix))]
    {
        let status = command
            .status()
            .with_context(|| format!("failed to launch {}", config.program.display()))?;
        if !status.success() {
            bail!("intercept worker command exited with status: {status}");
        }
        Ok(())
    }
}

fn spawn_parent_watchdog(parent_pid: u32) {
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_secs(1));
            #[cfg(unix)]
            {
                let result = unsafe { libc::kill(parent_pid as i32, 0) };
                if result != 0 {
                    std::process::exit(0);
                }
            }
            #[cfg(not(unix))]
            {
                let _ = parent_pid;
            }
        }
    });
}

fn timestamp_nanos() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}
