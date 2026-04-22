use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use chrono::{SecondsFormat, Utc};
use sandbox::NetConnectRule;
use serde::{Deserialize, Serialize};

pub const TERMINAL_TAB_ID_ENV: &str = "ARGON_TERMINAL_TAB_ID";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyHelperConfig {
    pub parent_pid: u32,
    pub allow_patterns: Vec<String>,
    pub log_path: Option<PathBuf>,
}

#[derive(Debug)]
pub struct ProxyRuntime {
    pub port: u16,
    pub environment: Vec<(String, String)>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ProxyActivityEvent {
    pub occurred_at: String,
    pub kind: String,
    pub outcome: String,
    pub method: Option<String>,
    pub host: String,
    pub port: u16,
    pub path: Option<String>,
    pub detail: Option<String>,
    pub bytes_up: u64,
    pub bytes_down: u64,
}

pub fn spawn_proxy_helper(
    current_exe: &Path,
    allow_patterns: &[String],
    log_path: Option<PathBuf>,
) -> Result<ProxyRuntime> {
    let runtime_dir = create_proxy_runtime_dir()?;
    let config_path = runtime_dir.join("config.json");
    let config = ProxyHelperConfig {
        parent_pid: std::process::id(),
        allow_patterns: allow_patterns.to_vec(),
        log_path,
    };
    fs::write(
        &config_path,
        serde_json::to_vec_pretty(&config).context("failed to serialize proxy config")?,
    )
    .with_context(|| format!("failed to write {}", config_path.display()))?;

    let mut child = Command::new(current_exe)
        .arg("sandbox")
        .arg("proxy-helper")
        .arg("--config")
        .arg(&config_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to launch sandbox proxy helper")?;

    let stdout = child
        .stdout
        .take()
        .context("proxy helper did not expose stdout")?;
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    let read = reader
        .read_line(&mut line)
        .context("failed to read proxy helper port")?;
    if read == 0 {
        let status = child.wait().context("failed to wait for proxy helper")?;
        bail!("proxy helper exited before reporting a port: {status}");
    }
    let port = line
        .trim()
        .parse::<u16>()
        .with_context(|| format!("invalid proxy helper port: {}", line.trim()))?;
    let proxy_url = format!("http://127.0.0.1:{port}");

    Ok(ProxyRuntime {
        port,
        environment: vec![
            ("HTTP_PROXY".to_string(), proxy_url.clone()),
            ("HTTPS_PROXY".to_string(), proxy_url.clone()),
            ("http_proxy".to_string(), proxy_url.clone()),
            ("https_proxy".to_string(), proxy_url),
        ],
    })
}

pub fn runtime_connect_rule(port: u16) -> NetConnectRule {
    NetConnectRule {
        protocol: sandbox::NetProtocol::Tcp,
        target: format!("127.0.0.1:{port}"),
    }
}

pub fn network_log_path_for_tab_id(tab_id: &str) -> PathBuf {
    std::env::temp_dir()
        .join("argon-sandbox-network")
        .join(format!("{tab_id}.ndjson"))
}

pub fn prepare_network_log_for_current_tab() -> Result<Option<PathBuf>> {
    let Some(tab_id) = std::env::var_os(TERMINAL_TAB_ID_ENV)
        .and_then(|value| value.into_string().ok())
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };

    let log_path = network_log_path_for_tab_id(&tab_id);
    if let Some(parent) = log_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    fs::write(&log_path, []).with_context(|| format!("failed to reset {}", log_path.display()))?;
    Ok(Some(log_path))
}

pub fn run_proxy_helper(config_path: &Path) -> Result<()> {
    let payload = fs::read_to_string(config_path)
        .with_context(|| format!("failed to read {}", config_path.display()))?;
    let config: ProxyHelperConfig =
        serde_json::from_str(&payload).context("failed to parse proxy config")?;

    let listener = TcpListener::bind(("127.0.0.1", 0)).context("failed to bind proxy listener")?;
    let port = listener
        .local_addr()
        .context("failed to read proxy listener addr")?
        .port();
    println!("{port}");
    io::stdout().flush().context("failed to flush proxy port")?;

    spawn_parent_watchdog(config.parent_pid);
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(stream) => stream,
            Err(error) => {
                eprintln!("sandbox proxy accept failed: {error}");
                continue;
            }
        };
        let allow_patterns = config.allow_patterns.clone();
        let log_path = config.log_path.clone();
        thread::spawn(move || {
            if let Err(error) = handle_client(stream, &allow_patterns, log_path.as_deref()) {
                eprintln!("sandbox proxy request failed: {error}");
            }
        });
    }
    Ok(())
}

fn create_proxy_runtime_dir() -> Result<PathBuf> {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "argon-sandbox-proxy-{}-{}",
        std::process::id(),
        nonce
    ));
    fs::create_dir_all(&path).with_context(|| format!("failed to create {}", path.display()))?;
    Ok(path)
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

fn handle_client(
    mut client: TcpStream,
    allow_patterns: &[String],
    log_path: Option<&Path>,
) -> Result<()> {
    let mut buffered = Vec::new();
    let header_end = read_http_headers(&mut client, &mut buffered)?;
    let header_bytes = &buffered[..header_end];
    let remainder = buffered[header_end..].to_vec();
    let header_text = String::from_utf8_lossy(header_bytes);
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next().context("missing proxy request line")?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next().context("missing proxy method")?;
    let target = parts.next().context("missing proxy target")?;
    let version = parts.next().context("missing proxy HTTP version")?;

    if method.eq_ignore_ascii_case("CONNECT") {
        let (host, port) = parse_authority(target)?;
        if !host_is_allowed(allow_patterns, &host) {
            record_proxy_event(
                log_path,
                ProxyActivityEvent {
                    occurred_at: timestamp_now(),
                    kind: "connect".to_string(),
                    outcome: "denied".to_string(),
                    method: Some("CONNECT".to_string()),
                    host: host.to_ascii_lowercase(),
                    port,
                    path: None,
                    detail: Some("proxy access denied by Sandboxfile".to_string()),
                    bytes_up: 0,
                    bytes_down: 0,
                },
            );
            bail!(
                "proxy access denied for host `{}`",
                host.to_ascii_lowercase()
            );
        }
        let upstream = TcpStream::connect((host.as_str(), port))
            .with_context(|| format!("failed to connect to {host}:{port}"))?;
        client
            .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            .context("failed to acknowledge CONNECT")?;
        let (bytes_up, bytes_down) = tunnel(client, upstream)?;
        record_proxy_event(
            log_path,
            ProxyActivityEvent {
                occurred_at: timestamp_now(),
                kind: "connect".to_string(),
                outcome: "proxied".to_string(),
                method: Some("CONNECT".to_string()),
                host: host.to_ascii_lowercase(),
                port,
                path: None,
                detail: None,
                bytes_up,
                bytes_down,
            },
        );
        return Ok(());
    }

    let (host, port, path_and_query) =
        parse_proxy_request_target(target, header_text.as_ref()).context("invalid proxy target")?;
    if !host_is_allowed(allow_patterns, &host) {
        record_proxy_event(
            log_path,
            ProxyActivityEvent {
                occurred_at: timestamp_now(),
                kind: "http".to_string(),
                outcome: "denied".to_string(),
                method: Some(method.to_string()),
                host: host.to_ascii_lowercase(),
                port,
                path: Some(path_and_query.clone()),
                detail: Some("proxy access denied by Sandboxfile".to_string()),
                bytes_up: 0,
                bytes_down: 0,
            },
        );
        bail!(
            "proxy access denied for host `{}`",
            host.to_ascii_lowercase()
        );
    }
    let mut upstream = TcpStream::connect((host.as_str(), port))
        .with_context(|| format!("failed to connect to {host}:{port}"))?;

    let mut forwarded = Vec::new();
    forwarded.extend_from_slice(format!("{method} {path_and_query} {version}\r\n").as_bytes());
    for line in header_text.split("\r\n").skip(1) {
        if line.is_empty() {
            continue;
        }
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("proxy-connection:") || lower.starts_with("connection:") {
            continue;
        }
        forwarded.extend_from_slice(line.as_bytes());
        forwarded.extend_from_slice(b"\r\n");
    }
    forwarded.extend_from_slice(b"Connection: close\r\n\r\n");
    forwarded.extend_from_slice(&remainder);
    upstream
        .write_all(&forwarded)
        .context("failed to forward proxied request")?;

    let (extra_bytes_up, bytes_down) = tunnel(client, upstream)?;
    record_proxy_event(
        log_path,
        ProxyActivityEvent {
            occurred_at: timestamp_now(),
            kind: "http".to_string(),
            outcome: "proxied".to_string(),
            method: Some(method.to_string()),
            host: host.to_ascii_lowercase(),
            port,
            path: Some(path_and_query),
            detail: None,
            bytes_up: forwarded.len() as u64 + extra_bytes_up,
            bytes_down,
        },
    );
    Ok(())
}

fn read_http_headers(stream: &mut TcpStream, buffer: &mut Vec<u8>) -> Result<usize> {
    let mut chunk = [0u8; 4096];
    loop {
        if let Some(index) = find_header_terminator(buffer) {
            return Ok(index);
        }
        let read = stream
            .read(&mut chunk)
            .context("failed to read proxy request")?;
        if read == 0 {
            bail!("proxy client closed before sending headers");
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.len() > 1024 * 1024 {
            bail!("proxy request headers are too large");
        }
    }
}

fn find_header_terminator(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|index| index + 4)
}

fn parse_authority(value: &str) -> Result<(String, u16)> {
    if let Some(stripped) = value.strip_prefix('[') {
        let (host, remainder) = stripped
            .split_once(']')
            .context("invalid CONNECT authority")?;
        let port = remainder
            .strip_prefix(':')
            .context("CONNECT authority is missing a port")?
            .parse::<u16>()
            .context("invalid CONNECT port")?;
        return Ok((host.to_string(), port));
    }

    let (host, port) = value
        .rsplit_once(':')
        .context("CONNECT authority is missing a port")?;
    Ok((
        host.to_string(),
        port.parse::<u16>().context("invalid CONNECT port")?,
    ))
}

fn parse_proxy_request_target(target: &str, headers: &str) -> Result<(String, u16, String)> {
    if let Some(rest) = target.strip_prefix("http://") {
        let (authority, path) = split_authority_and_path(rest);
        let (host, port) = parse_optional_port(authority, 80)?;
        let path = if path.is_empty() { "/" } else { path };
        return Ok((host, port, path.to_string()));
    }
    if let Some(rest) = target.strip_prefix("https://") {
        let (authority, path) = split_authority_and_path(rest);
        let (host, port) = parse_optional_port(authority, 443)?;
        let path = if path.is_empty() { "/" } else { path };
        return Ok((host, port, path.to_string()));
    }

    let host_header = headers
        .split("\r\n")
        .find_map(|line| {
            line.strip_prefix("Host:")
                .or_else(|| line.strip_prefix("host:"))
        })
        .map(str::trim)
        .context("proxy request is missing a Host header")?;
    let (host, port) = parse_optional_port(host_header, 80)?;
    let path = if target.is_empty() { "/" } else { target };
    Ok((host, port, path.to_string()))
}

fn split_authority_and_path(value: &str) -> (&str, &str) {
    match value.find('/') {
        Some(index) => (&value[..index], &value[index..]),
        None => (value, "/"),
    }
}

fn parse_optional_port(value: &str, default_port: u16) -> Result<(String, u16)> {
    if let Some(stripped) = value.strip_prefix('[') {
        let (host, remainder) = stripped
            .split_once(']')
            .context("invalid bracketed authority")?;
        if let Some(port) = remainder.strip_prefix(':') {
            return Ok((
                host.to_string(),
                port.parse::<u16>().context("invalid authority port")?,
            ));
        }
        return Ok((host.to_string(), default_port));
    }

    if let Some((host, port)) = value.rsplit_once(':') {
        if host.contains(':') {
            return Ok((value.to_string(), default_port));
        }
        if let Ok(port) = port.parse::<u16>() {
            return Ok((host.to_string(), port));
        }
    }
    Ok((value.to_string(), default_port))
}

fn host_is_allowed(patterns: &[String], host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    patterns.iter().any(|pattern| host_matches(pattern, &host))
}

fn record_proxy_event(log_path: Option<&Path>, event: ProxyActivityEvent) {
    let Some(log_path) = log_path else {
        return;
    };
    let Ok(serialized) = serde_json::to_string(&event) else {
        return;
    };
    let Ok(mut file) = OpenOptions::new().create(true).append(true).open(log_path) else {
        return;
    };
    let _ = writeln!(file, "{serialized}");
}

fn timestamp_now() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn host_matches(pattern: &str, host: &str) -> bool {
    let pattern = pattern.to_ascii_lowercase();
    if pattern == "*" {
        return true;
    }
    if let Some(suffix) = pattern.strip_prefix("*.") {
        return host.ends_with(&format!(".{suffix}"));
    }
    pattern == host
}

fn tunnel(client: TcpStream, upstream: TcpStream) -> Result<(u64, u64)> {
    let mut client_reader = client
        .try_clone()
        .context("failed to clone client stream")?;
    let mut client_writer = client;
    let mut upstream_reader = upstream
        .try_clone()
        .context("failed to clone upstream stream")?;
    let mut upstream_writer = upstream;

    let upload = thread::spawn(move || -> io::Result<u64> {
        let copied = io::copy(&mut client_reader, &mut upstream_writer)?;
        let _ = upstream_writer.shutdown(Shutdown::Write);
        Ok(copied)
    });
    let download = thread::spawn(move || -> io::Result<u64> {
        let copied = io::copy(&mut upstream_reader, &mut client_writer)?;
        let _ = client_writer.shutdown(Shutdown::Write);
        Ok(copied)
    });

    let bytes_up = upload
        .join()
        .map_err(|_| io::Error::other("proxy upload thread panicked"))?
        .context("proxy upload failed")?;
    let bytes_down = download
        .join()
        .map_err(|_| io::Error::other("proxy download thread panicked"))?
        .context("proxy download failed")?;
    Ok((bytes_up, bytes_down))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_matches_supports_wildcards() {
        assert!(host_matches("api.openai.com", "api.openai.com"));
        assert!(host_matches(
            "*.githubusercontent.com",
            "raw.githubusercontent.com"
        ));
        assert!(!host_matches(
            "*.githubusercontent.com",
            "githubusercontent.com"
        ));
        assert!(host_matches("*", "example.com"));
    }

    #[test]
    fn parse_proxy_request_absolute_url() {
        let parsed =
            parse_proxy_request_target("http://example.com:8080/demo?q=1", "Host: example.com\r\n")
                .expect("parsed");

        assert_eq!(
            parsed,
            ("example.com".to_string(), 8080, "/demo?q=1".to_string())
        );
    }

    #[test]
    fn network_log_path_is_tab_scoped() {
        let path = network_log_path_for_tab_id("abc-123");
        assert!(path.ends_with(Path::new("argon-sandbox-network/abc-123.ndjson")));
    }
}
