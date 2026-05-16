use std::collections::{BTreeMap, HashMap};
use std::ffi::{CStr, CString};
use std::io::Read;
use std::os::raw::c_char;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const SHELL_STARTUP_PATH_RESOLVED_ENV: &str = "ARGON_SHELL_STARTUP_PATH_RESOLVED";

const DEFAULT_INTERACTIVE_PATH_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Hash, PartialEq, Eq)]
struct InteractivePathCacheKey {
    shell: String,
    home: Option<String>,
    path: Option<String>,
    zdotdir: Option<String>,
}

static INTERACTIVE_PATH_CACHE: OnceLock<Mutex<HashMap<InteractivePathCacheKey, String>>> =
    OnceLock::new();

pub fn resolve_shell_path(environment: &BTreeMap<String, String>) -> PathBuf {
    if let Some(shell) = environment.get("SHELL").filter(|value| !value.is_empty()) {
        return PathBuf::from(shell);
    }

    #[cfg(unix)]
    {
        if let Some(shell) = login_shell_from_passwd() {
            return shell;
        }
    }

    PathBuf::from("/bin/zsh")
}

pub fn environment_with_interactive_path(
    environment: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    environment_with_interactive_path_timeout(environment, DEFAULT_INTERACTIVE_PATH_TIMEOUT)
}

pub fn environment_with_interactive_path_timeout(
    environment: &BTreeMap<String, String>,
    timeout: Duration,
) -> BTreeMap<String, String> {
    if environment
        .get(SHELL_STARTUP_PATH_RESOLVED_ENV)
        .map(|value| value == "1")
        .unwrap_or(false)
    {
        return environment.clone();
    }

    let Some(path) = resolve_interactive_path_cached(environment, timeout) else {
        return environment.clone();
    };

    let mut resolved_environment = environment.clone();
    resolved_environment.insert("PATH".to_string(), path);
    resolved_environment.insert(SHELL_STARTUP_PATH_RESOLVED_ENV.to_string(), "1".to_string());
    resolved_environment
}

pub fn resolve_interactive_path_cached(
    environment: &BTreeMap<String, String>,
    timeout: Duration,
) -> Option<String> {
    let shell = resolve_shell_path(environment).display().to_string();
    let cache_key = InteractivePathCacheKey {
        shell,
        home: environment.get("HOME").cloned(),
        path: environment.get("PATH").cloned(),
        zdotdir: environment.get("ZDOTDIR").cloned(),
    };

    let cache = INTERACTIVE_PATH_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(path) = cache
        .lock()
        .ok()
        .and_then(|cache| cache.get(&cache_key).cloned())
    {
        return Some(path);
    }

    let path = resolve_interactive_path_uncached(environment, timeout)?;
    if let Ok(mut cache) = cache.lock() {
        cache.insert(cache_key, path.clone());
    }
    Some(path)
}

fn resolve_interactive_path_uncached(
    environment: &BTreeMap<String, String>,
    timeout: Duration,
) -> Option<String> {
    let shell = resolve_shell_path(environment);
    let marker = unique_marker();
    let script = format!(
        "printf '%s\\n' {}\nprintf '%s\\n' \"$PATH\"\nprintf '%s\\n' {}\n",
        shell_quote(&marker),
        shell_quote(&marker)
    );

    let mut child = Command::new(shell)
        .args(["-i", "-l", "-c", &script])
        .env_clear()
        .envs(environment)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    let mut stdout = child.stdout.take()?;
    let output_reader = thread::spawn(move || {
        let mut output = String::new();
        let _ = stdout.read_to_string(&mut output);
        output
    });

    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().ok()? {
            break status;
        }
        if start.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        thread::sleep(Duration::from_millis(10));
    };

    if !status.success() {
        return None;
    }

    let output = output_reader.join().ok()?;
    parse_interactive_path_probe_output(&output, &marker)
}

fn parse_interactive_path_probe_output(output: &str, marker: &str) -> Option<String> {
    let lines = output.lines().collect::<Vec<_>>();
    let start = lines.iter().position(|line| *line == marker)?;
    let end = lines
        .iter()
        .enumerate()
        .skip(start + 1)
        .find_map(|(index, line)| (*line == marker).then_some(index))?;

    if end != start + 2 {
        return None;
    }

    let path = lines[start + 1].trim();
    (!path.is_empty()).then(|| path.to_string())
}

fn unique_marker() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("__ARGON_SHELL_PATH_{}_{}__", std::process::id(), nanos)
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(unix)]
fn login_shell_from_passwd() -> Option<PathBuf> {
    let passwd = unsafe { libc::getpwuid(libc::getuid()) };
    if passwd.is_null() {
        return None;
    }

    let shell = unsafe { (*passwd).pw_shell };
    if shell.is_null() {
        return None;
    }

    let shell = unsafe { CStr::from_ptr(shell) }.to_string_lossy();
    (!shell.is_empty()).then(|| PathBuf::from(shell.as_ref()))
}

/// Resolve the PATH produced by the user's interactive login shell.
///
/// # Safety
///
/// `environment_json` must be null or point to a valid NUL-terminated C string
/// containing a JSON object with string keys and string values. The returned
/// pointer must be released exactly once with `argonlib_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_resolve_interactive_path_json(
    environment_json: *const c_char,
    timeout_ms: u64,
) -> *mut c_char {
    let Some(environment_json) = string_from_c_pointer(environment_json) else {
        return std::ptr::null_mut();
    };
    let Ok(environment) = serde_json::from_str::<BTreeMap<String, String>>(&environment_json)
    else {
        return std::ptr::null_mut();
    };
    let Some(path) =
        resolve_interactive_path_cached(&environment, Duration::from_millis(timeout_ms.max(1)))
    else {
        return std::ptr::null_mut();
    };

    CString::new(path)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// Free a string returned by an `argon-lib` C ABI function.
///
/// # Safety
///
/// `value` must be null or a pointer previously returned by an `argon-lib`
/// function that transfers ownership to the caller. Passing any other pointer,
/// or passing the same pointer more than once, is undefined behavior.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    let _ = unsafe { CString::from_raw(value) };
}

fn string_from_c_pointer(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    Some(
        unsafe { CStr::from_ptr(value) }
            .to_string_lossy()
            .into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn environment_with_interactive_path_reads_shell_startup_path() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let shell_path = temp_dir.path().join("fake-shell.sh");
        fs::write(
            &shell_path,
            "#!/bin/sh\nfor last do :; done\nPATH='/custom/bin:/usr/bin:/bin'\neval \"$last\"\n",
        )
        .expect("write shell");
        set_executable(&shell_path);

        let mut environment = BTreeMap::new();
        environment.insert("PATH".to_string(), "/usr/bin:/bin".to_string());
        environment.insert("SHELL".to_string(), shell_path.display().to_string());

        let resolved =
            environment_with_interactive_path_timeout(&environment, Duration::from_secs(1));

        assert_eq!(
            resolved.get("PATH").map(String::as_str),
            Some("/custom/bin:/usr/bin:/bin")
        );
        assert_eq!(
            resolved
                .get(SHELL_STARTUP_PATH_RESOLVED_ENV)
                .map(String::as_str),
            Some("1")
        );
    }

    #[test]
    fn environment_with_interactive_path_keeps_marked_environment() {
        let mut environment = BTreeMap::new();
        environment.insert("PATH".to_string(), "/already/resolved".to_string());
        environment.insert(SHELL_STARTUP_PATH_RESOLVED_ENV.to_string(), "1".to_string());

        let resolved =
            environment_with_interactive_path_timeout(&environment, Duration::from_millis(1));

        assert_eq!(resolved, environment);
    }

    #[test]
    fn ffi_returns_null_for_invalid_json() {
        let input = CString::new("not-json").expect("cstring");
        let result = unsafe { argonlib_resolve_interactive_path_json(input.as_ptr(), 100) };
        assert!(result.is_null());
    }

    #[cfg(unix)]
    fn set_executable(path: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(path).expect("metadata").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).expect("permissions");
    }

    #[cfg(not(unix))]
    fn set_executable(_path: &std::path::Path) {}
}
