use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

const REPO_CONFIG_BASENAME: &str = ".sandbox";
const USER_CONFIG_BASENAME: &str = "sandbox";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SandboxPolicy {
    writable_paths: Vec<PathBuf>,
    writable_roots: Vec<PathBuf>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigScope {
    User,
    Repo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigFormat {
    Yaml,
    Yml,
    Toml,
    Json,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigTarget {
    Base,
    Macos,
    Linux,
    Windows,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResolvedConfigPaths {
    pub repo_default_path: Option<PathBuf>,
    pub repo_existing_path: Option<PathBuf>,
    pub user_default_path: PathBuf,
    pub user_existing_path: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SandboxConfig {
    #[serde(flatten)]
    pub base: SandboxConfigSection,
    #[serde(default, skip_serializing_if = "SandboxConfigSection::is_empty")]
    pub macos: SandboxConfigSection,
    #[serde(default, skip_serializing_if = "SandboxConfigSection::is_empty")]
    pub linux: SandboxConfigSection,
    #[serde(default, skip_serializing_if = "SandboxConfigSection::is_empty")]
    pub windows: SandboxConfigSection,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SandboxConfigSection {
    pub include_defaults: Option<bool>,
    #[serde(default)]
    pub write_paths: Vec<PathBuf>,
    #[serde(default)]
    pub write_roots: Vec<PathBuf>,
}

#[derive(Debug, Clone, Default)]
struct SandboxRules {
    writable_paths: Vec<PathBuf>,
    writable_roots: Vec<PathBuf>,
}

#[derive(Debug, Error)]
pub enum SandboxError {
    #[error("sandbox policy must allow at least one writable location")]
    NoWritableLocations,
    #[error("sandbox writable location must be absolute: {0}")]
    RelativeWritableLocation(PathBuf),
    #[error("sandbox path contains a NUL byte: {0}")]
    NulPath(PathBuf),
    #[error("failed to read sandbox config at {path}: {source}")]
    ConfigRead {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("failed to parse sandbox config at {path}: {message}")]
    ConfigParse { path: PathBuf, message: String },
    #[error("found multiple {scope} sandbox config files: {paths:?}")]
    MultipleConfigFiles {
        scope: &'static str,
        paths: Vec<PathBuf>,
    },
    #[error("repo-root sandbox config operations require a repository root")]
    MissingRepoRoot,
    #[error("could not determine a global config directory from XDG_CONFIG_HOME or HOME")]
    MissingUserConfigHome,
    #[error("could not expand sandbox path because HOME is not set: {0}")]
    MissingHomeForExpansion(PathBuf),
    #[error("sandboxing is not supported on this platform")]
    UnsupportedPlatform,
    #[error("failed to apply macOS sandbox: {0}")]
    MacOsApi(String),
}

impl ConfigFormat {
    fn extension(self) -> &'static str {
        match self {
            Self::Yaml => "yaml",
            Self::Yml => "yml",
            Self::Toml => "toml",
            Self::Json => "json",
        }
    }

    fn all() -> [Self; 4] {
        [Self::Yaml, Self::Yml, Self::Toml, Self::Json]
    }

    fn from_path(path: &Path) -> Option<Self> {
        match path.extension().and_then(OsStr::to_str) {
            Some("yaml") => Some(Self::Yaml),
            Some("yml") => Some(Self::Yml),
            Some("toml") => Some(Self::Toml),
            Some("json") => Some(Self::Json),
            _ => None,
        }
    }
}

impl SandboxConfig {
    pub fn section(&self, target: ConfigTarget) -> &SandboxConfigSection {
        match target {
            ConfigTarget::Base => &self.base,
            ConfigTarget::Macos => &self.macos,
            ConfigTarget::Linux => &self.linux,
            ConfigTarget::Windows => &self.windows,
        }
    }

    pub fn section_mut(&mut self, target: ConfigTarget) -> &mut SandboxConfigSection {
        match target {
            ConfigTarget::Base => &mut self.base,
            ConfigTarget::Macos => &mut self.macos,
            ConfigTarget::Linux => &mut self.linux,
            ConfigTarget::Windows => &mut self.windows,
        }
    }
}

impl SandboxConfigSection {
    fn is_empty(&self) -> bool {
        self.include_defaults.is_none()
            && self.write_paths.is_empty()
            && self.write_roots.is_empty()
    }
}

impl SandboxPolicy {
    pub fn built_in_defaults() -> Self {
        let mut rules = SandboxRules::default();
        append_built_in_defaults(&mut rules);
        Self {
            writable_paths: rules.writable_paths,
            writable_roots: rules.writable_roots,
        }
    }

    pub fn read_only_with_writable_roots<I, P>(roots: I) -> Result<Self, SandboxError>
    where
        I: IntoIterator<Item = P>,
        P: Into<PathBuf>,
    {
        Self::read_only_with_writable_roots_for_repo(roots, None::<&Path>)
    }

    pub fn read_only_with_writable_roots_for_repo<I, P>(
        roots: I,
        repo_root: Option<&Path>,
    ) -> Result<Self, SandboxError>
    where
        I: IntoIterator<Item = P>,
        P: Into<PathBuf>,
    {
        let user_config = load_scope_config(ConfigScope::User, None)?;
        let repo_config = load_scope_config(ConfigScope::Repo, repo_root)?;
        let current_target = current_os_target();

        let include_defaults = repo_config
            .as_ref()
            .map(|config| config.section(current_target))
            .and_then(|section| section.include_defaults)
            .or_else(|| {
                repo_config
                    .as_ref()
                    .and_then(|config| config.base.include_defaults)
            })
            .or_else(|| {
                user_config
                    .as_ref()
                    .map(|config| config.section(current_target))
                    .and_then(|section| section.include_defaults)
            })
            .or_else(|| {
                user_config
                    .as_ref()
                    .and_then(|config| config.base.include_defaults)
            })
            .unwrap_or(true);

        let mut rules = SandboxRules::default();
        if include_defaults {
            append_built_in_defaults(&mut rules);
        }

        if let Some(config) = user_config.as_ref() {
            merge_config(&mut rules, config, None, current_target)?;
        }
        if let Some(config) = repo_config.as_ref() {
            merge_config(&mut rules, config, repo_root, current_target)?;
        }
        for root in roots {
            rules.push_root(root.into())?;
        }

        if rules.writable_paths.is_empty() && rules.writable_roots.is_empty() {
            return Err(SandboxError::NoWritableLocations);
        }

        Ok(Self {
            writable_paths: rules.writable_paths,
            writable_roots: rules.writable_roots,
        })
    }

    pub fn writable_paths(&self) -> &[PathBuf] {
        &self.writable_paths
    }

    pub fn writable_roots(&self) -> &[PathBuf] {
        &self.writable_roots
    }
}

pub fn resolved_config_paths(
    repo_root: Option<&Path>,
) -> Result<ResolvedConfigPaths, SandboxError> {
    Ok(ResolvedConfigPaths {
        repo_default_path: repo_root.map(default_repo_config_path),
        repo_existing_path: find_scope_config_path(ConfigScope::Repo, repo_root)?,
        user_default_path: default_user_config_path()?,
        user_existing_path: find_scope_config_path(ConfigScope::User, None)?,
    })
}

pub fn load_scope_config(
    scope: ConfigScope,
    repo_root: Option<&Path>,
) -> Result<Option<SandboxConfig>, SandboxError> {
    let Some(path) = find_scope_config_path(scope, repo_root)? else {
        return Ok(None);
    };

    let payload = fs::read_to_string(&path).map_err(|source| SandboxError::ConfigRead {
        path: path.clone(),
        source,
    })?;
    let format = ConfigFormat::from_path(&path)
        .expect("discovered sandbox config should always use a supported format");
    let config = match format {
        ConfigFormat::Yaml | ConfigFormat::Yml => {
            serde_yaml::from_str(&payload).map_err(|error| SandboxError::ConfigParse {
                path: path.clone(),
                message: error.to_string(),
            })?
        }
        ConfigFormat::Toml => {
            toml::from_str(&payload).map_err(|error| SandboxError::ConfigParse {
                path: path.clone(),
                message: error.to_string(),
            })?
        }
        ConfigFormat::Json => {
            serde_json::from_str(&payload).map_err(|error| SandboxError::ConfigParse {
                path: path.clone(),
                message: error.to_string(),
            })?
        }
    };

    Ok(Some(config))
}

pub fn save_scope_config(
    scope: ConfigScope,
    repo_root: Option<&Path>,
    config: &SandboxConfig,
    preferred_format: Option<ConfigFormat>,
) -> Result<PathBuf, SandboxError> {
    let existing_path = find_scope_config_path(scope, repo_root)?;
    let path = match existing_path {
        Some(path) => path,
        None => match scope {
            ConfigScope::Repo => {
                let repo_root = repo_root.ok_or(SandboxError::MissingRepoRoot)?;
                default_repo_config_path_with_format(
                    repo_root,
                    preferred_format.unwrap_or(ConfigFormat::Yaml),
                )
            }
            ConfigScope::User => default_user_config_path_with_format(
                preferred_format.unwrap_or(ConfigFormat::Yaml),
            )?,
        },
    };

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| SandboxError::ConfigRead {
            path: parent.to_path_buf(),
            source,
        })?;
    }

    let format = ConfigFormat::from_path(&path)
        .expect("save target should always use a supported config extension");
    let payload = match format {
        ConfigFormat::Yaml | ConfigFormat::Yml => {
            serde_yaml::to_string(config).map_err(|error| SandboxError::ConfigParse {
                path: path.clone(),
                message: error.to_string(),
            })?
        }
        ConfigFormat::Toml => {
            toml::to_string_pretty(config).map_err(|error| SandboxError::ConfigParse {
                path: path.clone(),
                message: error.to_string(),
            })?
        }
        ConfigFormat::Json => {
            serde_json::to_string_pretty(config).map_err(|error| SandboxError::ConfigParse {
                path: path.clone(),
                message: error.to_string(),
            })?
        }
    };

    fs::write(&path, payload).map_err(|source| SandboxError::ConfigRead {
        path: path.clone(),
        source,
    })?;
    Ok(path)
}

pub fn apply_current_process(policy: &SandboxPolicy) -> Result<(), SandboxError> {
    platform::apply_current_process(policy)
}

pub fn profile_source(policy: &SandboxPolicy) -> String {
    let mut lines = vec![
        "(version 1)".to_string(),
        "(allow default)".to_string(),
        "(deny file-write*)".to_string(),
    ];

    for (index, _) in policy.writable_paths.iter().enumerate() {
        lines.push(format!(
            "(allow file-write* (path (param \"WRITE_PATH_{index}\")))"
        ));
    }

    for (index, _) in policy.writable_roots.iter().enumerate() {
        lines.push(format!(
            "(allow file-write* (subpath (param \"WRITE_ROOT_{index}\")))"
        ));
    }

    lines.join("\n")
}

pub fn profile_parameters(policy: &SandboxPolicy) -> Vec<String> {
    let mut params =
        Vec::with_capacity((policy.writable_paths.len() + policy.writable_roots.len()) * 2);
    for (index, path) in policy.writable_paths.iter().enumerate() {
        params.push(format!("WRITE_PATH_{index}"));
        params.push(path.to_string_lossy().into_owned());
    }
    for (index, root) in policy.writable_roots.iter().enumerate() {
        params.push(format!("WRITE_ROOT_{index}"));
        params.push(root.to_string_lossy().into_owned());
    }
    params
}

fn append_built_in_defaults(rules: &mut SandboxRules) {
    rules.push_path(PathBuf::from("/dev/null")).ok();
    rules.push_root(std::env::temp_dir()).ok();

    if let Some(path) = non_empty_env_path("TMPDIR") {
        rules.push_root(path).ok();
    }
    if let Some(path) = non_empty_env_path("XDG_STATE_HOME") {
        rules.push_root(path).ok();
    }
    if let Some(path) = non_empty_env_path("XDG_CACHE_HOME") {
        rules.push_root(path).ok();
    }
    if let Some(home) = non_empty_env_path("HOME") {
        rules.push_path(home.join(".claude.json")).ok();
        for root in [
            home.join(".local").join("state"),
            home.join(".cache"),
            home.join("Library").join("Caches"),
            home.join(".claude"),
            home.join(".claude.json.lock"),
            home.join(".codex"),
            home.join(".gemini"),
        ] {
            rules.push_root(root).ok();
        }
    }
}

fn merge_config(
    rules: &mut SandboxRules,
    config: &SandboxConfig,
    repo_root: Option<&Path>,
    current_target: ConfigTarget,
) -> Result<(), SandboxError> {
    for path in &config.base.write_paths {
        rules.push_path(resolve_config_path(path, repo_root)?)?;
    }
    for root in &config.base.write_roots {
        rules.push_root(resolve_config_path(root, repo_root)?)?;
    }
    let os_section = config.section(current_target);
    for path in &os_section.write_paths {
        rules.push_path(resolve_config_path(path, repo_root)?)?;
    }
    for root in &os_section.write_roots {
        rules.push_root(resolve_config_path(root, repo_root)?)?;
    }
    Ok(())
}

fn resolve_config_path(path: &Path, repo_root: Option<&Path>) -> Result<PathBuf, SandboxError> {
    let path = expand_home_shorthand(path)?;

    if path.is_absolute() {
        return Ok(path);
    }

    let repo_root =
        repo_root.ok_or_else(|| SandboxError::RelativeWritableLocation(path.clone()))?;
    Ok(repo_root.join(path))
}

fn current_os_target() -> ConfigTarget {
    #[cfg(target_os = "macos")]
    {
        ConfigTarget::Macos
    }
    #[cfg(target_os = "linux")]
    {
        ConfigTarget::Linux
    }
    #[cfg(target_os = "windows")]
    {
        ConfigTarget::Windows
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        ConfigTarget::Base
    }
}

fn find_scope_config_path(
    scope: ConfigScope,
    repo_root: Option<&Path>,
) -> Result<Option<PathBuf>, SandboxError> {
    if matches!(scope, ConfigScope::Repo) && repo_root.is_none() {
        return Ok(None);
    }
    let candidates = candidate_paths(scope, repo_root)?;
    let existing = candidates
        .into_iter()
        .filter(|path| path.is_file())
        .collect::<Vec<_>>();

    match existing.len() {
        0 => Ok(None),
        1 => Ok(existing.into_iter().next()),
        _ => Err(SandboxError::MultipleConfigFiles {
            scope: match scope {
                ConfigScope::User => "user",
                ConfigScope::Repo => "repo",
            },
            paths: existing,
        }),
    }
}

fn candidate_paths(
    scope: ConfigScope,
    repo_root: Option<&Path>,
) -> Result<Vec<PathBuf>, SandboxError> {
    let base = match scope {
        ConfigScope::Repo => {
            let repo_root = repo_root.ok_or(SandboxError::MissingRepoRoot)?;
            repo_root.to_path_buf()
        }
        ConfigScope::User => user_config_base_dir()?,
    };
    let basename = match scope {
        ConfigScope::Repo => REPO_CONFIG_BASENAME,
        ConfigScope::User => USER_CONFIG_BASENAME,
    };

    Ok(ConfigFormat::all()
        .into_iter()
        .map(|format| base.join(format!("{basename}.{}", format.extension())))
        .collect())
}

fn default_repo_config_path(repo_root: &Path) -> PathBuf {
    default_repo_config_path_with_format(repo_root, ConfigFormat::Yaml)
}

fn default_repo_config_path_with_format(repo_root: &Path, format: ConfigFormat) -> PathBuf {
    repo_root.join(format!("{REPO_CONFIG_BASENAME}.{}", format.extension()))
}

fn default_user_config_path() -> Result<PathBuf, SandboxError> {
    default_user_config_path_with_format(ConfigFormat::Yaml)
}

fn default_user_config_path_with_format(format: ConfigFormat) -> Result<PathBuf, SandboxError> {
    Ok(user_config_base_dir()?.join(format!("{USER_CONFIG_BASENAME}.{}", format.extension())))
}

fn user_config_base_dir() -> Result<PathBuf, SandboxError> {
    if let Some(path) = non_empty_env_path("XDG_CONFIG_HOME") {
        return Ok(path.join("argon"));
    }
    if let Some(path) = non_empty_env_path("HOME") {
        return Ok(path.join(".config").join("argon"));
    }
    Err(SandboxError::MissingUserConfigHome)
}

fn non_empty_env_path(name: &str) -> Option<PathBuf> {
    let value = std::env::var_os(name)?;
    if value.is_empty() {
        return None;
    }
    Some(PathBuf::from(value))
}

impl SandboxRules {
    fn push_path(&mut self, path: PathBuf) -> Result<(), SandboxError> {
        let path = normalize_location(path)?;
        if !self.writable_paths.contains(&path) {
            self.writable_paths.push(path);
        }
        Ok(())
    }

    fn push_root(&mut self, root: PathBuf) -> Result<(), SandboxError> {
        let root = normalize_location(root)?;
        if !self.writable_roots.contains(&root) {
            self.writable_roots.push(root);
        }
        Ok(())
    }
}

fn normalize_location(path: PathBuf) -> Result<PathBuf, SandboxError> {
    if !path.is_absolute() {
        return Err(SandboxError::RelativeWritableLocation(path));
    }

    Ok(fs::canonicalize(&path).unwrap_or(path))
}

pub fn normalize_config_input_path(path: &Path) -> Result<PathBuf, SandboxError> {
    expand_home_shorthand(path)
}

fn expand_home_shorthand(path: &Path) -> Result<PathBuf, SandboxError> {
    let raw = path.to_string_lossy();
    let (prefix, suffix) = if raw == "~" {
        ("~", "")
    } else if let Some(suffix) = raw.strip_prefix("~/") {
        ("~/", suffix)
    } else if raw == "$HOME" {
        ("$HOME", "")
    } else if let Some(suffix) = raw.strip_prefix("$HOME/") {
        ("$HOME/", suffix)
    } else if raw == "${HOME}" {
        ("${HOME}", "")
    } else if let Some(suffix) = raw.strip_prefix("${HOME}/") {
        ("${HOME}/", suffix)
    } else {
        return Ok(path.to_path_buf());
    };

    let home = non_empty_env_path("HOME")
        .ok_or_else(|| SandboxError::MissingHomeForExpansion(path.to_path_buf()))?;
    if suffix.is_empty() {
        return Ok(home);
    }

    let relative = PathBuf::from(suffix);
    debug_assert!(
        !relative.is_absolute(),
        "expanded suffix from {prefix} should be relative"
    );
    Ok(home.join(relative))
}

#[cfg(target_os = "macos")]
mod platform {
    use std::ffi::{CStr, CString};
    use std::os::raw::{c_char, c_int};
    use std::ptr;

    use super::{SandboxError, SandboxPolicy, profile_parameters, profile_source};

    #[link(name = "sandbox")]
    unsafe extern "C" {
        fn sandbox_init_with_parameters(
            profile: *const c_char,
            flags: u64,
            parameters: *const *const c_char,
            errorbuf: *mut *mut c_char,
        ) -> c_int;
        fn sandbox_free_error(errorbuf: *mut c_char);
    }

    pub fn apply_current_process(policy: &SandboxPolicy) -> Result<(), SandboxError> {
        let path_for_error = policy
            .writable_paths()
            .first()
            .or_else(|| policy.writable_roots().first())
            .cloned()
            .unwrap_or_else(|| PathBuf::from("/dev/null"));
        let profile = CString::new(profile_source(policy))
            .map_err(|_| SandboxError::NulPath(path_for_error))?;
        let raw_params = profile_parameters(policy);
        let params = raw_params
            .iter()
            .map(|value| {
                CString::new(value.as_str()).map_err(|_| SandboxError::NulPath(value.into()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut param_ptrs = params
            .iter()
            .map(|value| value.as_ptr())
            .collect::<Vec<_>>();
        param_ptrs.push(ptr::null());

        let mut errorbuf: *mut c_char = ptr::null_mut();
        let result = unsafe {
            sandbox_init_with_parameters(profile.as_ptr(), 0, param_ptrs.as_ptr(), &mut errorbuf)
        };

        if result == 0 {
            return Ok(());
        }

        let message = if errorbuf.is_null() {
            "unknown sandbox error".to_string()
        } else {
            let message = unsafe { CStr::from_ptr(errorbuf) }
                .to_string_lossy()
                .into_owned();
            unsafe {
                sandbox_free_error(errorbuf);
            }
            message
        };

        Err(SandboxError::MacOsApi(message))
    }

    use std::path::PathBuf;
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::{SandboxError, SandboxPolicy};

    pub fn apply_current_process(_policy: &SandboxPolicy) -> Result<(), SandboxError> {
        Err(SandboxError::UnsupportedPlatform)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn built_in_defaults_include_dev_null_and_state_roots() {
        let policy = SandboxPolicy::built_in_defaults();
        assert!(
            policy
                .writable_paths()
                .iter()
                .any(|path| path == Path::new("/dev/null"))
        );
        if let Some(home) = non_empty_env_path("HOME") {
            assert!(
                policy
                    .writable_paths()
                    .iter()
                    .any(|path| path == &home.join(".claude.json"))
            );
            assert!(
                policy
                    .writable_roots()
                    .iter()
                    .any(|path| path == &home.join(".claude.json.lock"))
            );
        }
    }

    #[test]
    fn config_disables_defaults_and_resolves_relative_repo_paths() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(repo_root.join("custom-state")).expect("create repo dirs");
        fs::write(
            repo_root.join(".sandbox.yaml"),
            "include_defaults: false\nwrite_roots:\n  - custom-state\nwrite_paths:\n  - /dev/null\n",
        )
        .expect("write config");

        let policy = SandboxPolicy::read_only_with_writable_roots_for_repo(
            [repo_root.join("worktree")],
            Some(&repo_root),
        )
        .expect("policy");
        let custom_state = repo_root
            .join("custom-state")
            .canonicalize()
            .expect("canonical state");

        assert_eq!(policy.writable_paths(), &[PathBuf::from("/dev/null")]);
        assert!(
            policy
                .writable_roots()
                .iter()
                .any(|path| path == &custom_state)
        );
        assert!(
            !policy
                .writable_roots()
                .iter()
                .any(|path| path.ends_with(".local/state"))
        );
    }

    #[test]
    fn os_specific_section_extends_base_config() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(repo_root.join("base-root")).expect("create base root");
        fs::create_dir_all(repo_root.join("mac-root")).expect("create mac root");
        fs::write(
            repo_root.join(".sandbox.yaml"),
            "write_roots:\n  - base-root\nmacos:\n  write_roots:\n    - mac-root\n",
        )
        .expect("write config");

        let policy = SandboxPolicy::read_only_with_writable_roots_for_repo(
            [repo_root.join("worktree")],
            Some(&repo_root),
        )
        .expect("policy");
        let base_root = repo_root
            .join("base-root")
            .canonicalize()
            .expect("base root");
        let mac_root = repo_root.join("mac-root").canonicalize().expect("mac root");

        assert!(
            policy
                .writable_roots()
                .iter()
                .any(|path| path == &base_root)
        );
        #[cfg(target_os = "macos")]
        assert!(policy.writable_roots().iter().any(|path| path == &mac_root));
    }

    #[test]
    fn multiple_repo_configs_error() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("create repo");
        fs::write(repo_root.join(".sandbox.yaml"), "include_defaults: true\n").expect("yaml");
        fs::write(repo_root.join(".sandbox.toml"), "include_defaults = true\n").expect("toml");

        let error = SandboxPolicy::read_only_with_writable_roots_for_repo(
            [repo_root.join("worktree")],
            Some(&repo_root),
        )
        .expect_err("multiple configs should fail");

        assert!(matches!(error, SandboxError::MultipleConfigFiles { .. }));
    }

    #[test]
    fn config_expands_home_shorthand() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let fake_home = temp.path().join("home");
        fs::create_dir_all(repo_root.join("repo-root")).expect("create repo root");
        fs::create_dir_all(fake_home.join(".claude.json.lock")).expect("create home lock dir");
        fs::create_dir_all(fake_home.join(".gemini")).expect("create home gemini dir");
        fs::write(
            repo_root.join(".sandbox.yaml"),
            "write_roots:\n  - ~/.claude.json.lock\n  - ${HOME}/.gemini\n  - repo-root\nwrite_paths:\n  - $HOME/.claude.json\n",
        )
        .expect("write config");

        let previous_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", &fake_home);
        }

        let policy = SandboxPolicy::read_only_with_writable_roots_for_repo(
            [repo_root.join("worktree")],
            Some(&repo_root),
        )
        .expect("policy");
        let claude_lock_root = fake_home
            .join(".claude.json.lock")
            .canonicalize()
            .expect("canonical lock root");
        let gemini_root = fake_home
            .join(".gemini")
            .canonicalize()
            .expect("canonical gemini root");
        let repo_config_root = repo_root
            .join("repo-root")
            .canonicalize()
            .expect("canonical repo root");

        if let Some(home) = previous_home {
            unsafe {
                std::env::set_var("HOME", home);
            }
        } else {
            unsafe {
                std::env::remove_var("HOME");
            }
        }

        assert!(
            policy
                .writable_paths()
                .iter()
                .any(|path| path == &fake_home.join(".claude.json"))
        );
        assert!(
            policy
                .writable_roots()
                .iter()
                .any(|path| path == &claude_lock_root)
        );
        assert!(
            policy
                .writable_roots()
                .iter()
                .any(|path| path == &gemini_root)
        );
        assert!(
            policy
                .writable_roots()
                .iter()
                .any(|path| path == &repo_config_root)
        );
    }
}
