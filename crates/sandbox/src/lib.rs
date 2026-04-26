mod builtins;
mod parser;

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use parser::{InterceptHandler, ParsedProgram, StatementKind};

const REPO_SANDBOXFILE: &str = "Sandboxfile";
const USER_SANDBOXFILE: &str = ".Sandboxfile";
const USER_SANDBOXFILE_COMPAT: &str = ".Sanboxfile";
pub const INTERCEPT_RUNNER_ENV: &str = "ARGON_SANDBOX_INTERCEPT_RUNNER";
pub const INTERCEPT_SOCKET_ENV: &str = "ARGON_SANDBOX_INTERCEPT_SOCKET";
pub const INTERCEPT_TOKEN_ENV: &str = "ARGON_SANDBOX_INTERCEPT_TOKEN";
pub const INTERCEPT_COMMAND_ENV: &str = "ARGON_SANDBOX_INTERCEPT_COMMAND";
pub const ARGON_INFO_ENV: &str = "ARGON_INFO";
pub const ARGON_WARN_ENV: &str = "ARGON_WARN";
pub const ARGON_ERROR_ENV: &str = "ARGON_ERROR";
pub const ARGON_EXEC_ENV: &str = "ARGON_EXEC";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LaunchKind {
    Command,
    Shell,
    Agent,
    Reviewer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FsDefault {
    None,
    Read,
    ReadWrite,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecDefault {
    Allow,
    Deny,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NetDefault {
    Allow,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EnvDefault {
    Inherit,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FsAccess {
    Read,
    Write,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NetProtocol {
    Tcp,
    Udp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NetConnectRule {
    pub protocol: NetProtocol,
    pub target: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SandboxContext {
    pub repo_root: Option<PathBuf>,
    pub current_dir: PathBuf,
    pub launch: LaunchKind,
    pub interactive: bool,
    pub shell: Option<String>,
    pub shell_path: Option<PathBuf>,
    pub agent: Option<String>,
    pub session_dir: Option<PathBuf>,
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedConfigEntry {
    pub directory: PathBuf,
    pub sandboxfile_path: PathBuf,
    pub dot_sandboxfile_path: PathBuf,
    pub compatibility_path: PathBuf,
    pub existing_path: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedConfigPaths {
    pub init_path: Option<PathBuf>,
    pub entries: Vec<ResolvedConfigEntry>,
    pub existing_paths: Vec<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SandboxInitResult {
    pub path: PathBuf,
    pub created: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinPreview {
    pub requested_name: String,
    pub resolved_name: Option<String>,
    pub source: Option<String>,
    pub infos: Vec<String>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExplainedSource {
    pub kind: String,
    pub name: String,
    pub path: Option<PathBuf>,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EffectiveSandboxPolicy {
    pub fs_default: FsDefault,
    pub exec_default: ExecDefault,
    pub net_default: NetDefault,
    pub readable_paths: Vec<PathBuf>,
    pub readable_roots: Vec<PathBuf>,
    pub writable_paths: Vec<PathBuf>,
    pub writable_roots: Vec<PathBuf>,
    pub executable_paths: Vec<PathBuf>,
    pub executable_roots: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub denied_readable_paths: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub denied_readable_roots: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub denied_writable_paths: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub denied_writable_roots: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub denied_executable_paths: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub denied_executable_roots: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub local_socket_paths: Vec<PathBuf>,
    pub proxied_hosts: Vec<String>,
    pub connect_rules: Vec<NetConnectRule>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedIntercept {
    pub command_name: String,
    pub handler_path: PathBuf,
    pub handler_kind: InterceptHandlerKind,
    pub handler_write_protected: bool,
    pub real_command_path: Option<PathBuf>,
    pub shim_path: Option<PathBuf>,
    pub exec_helper_path: Option<PathBuf>,
    #[serde(skip)]
    inline_script: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InterceptHandlerKind {
    File,
    InlineScript,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InterceptBrokerPlan {
    pub runtime_dir: PathBuf,
    pub bin_dir: PathBuf,
    pub helper_dir: PathBuf,
    pub info_helper_path: PathBuf,
    pub warn_helper_path: PathBuf,
    pub error_helper_path: PathBuf,
    pub exec_helper_path: PathBuf,
    pub socket_path: PathBuf,
    pub token: String,
    pub original_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SandboxExplain {
    pub context: BTreeMap<String, String>,
    pub paths: ResolvedConfigPaths,
    pub sources: Vec<ExplainedSource>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub protected_sandbox_files: Vec<PathBuf>,
    pub infos: Vec<String>,
    pub warnings: Vec<String>,
    pub policy: EffectiveSandboxPolicy,
    pub intercepts: Vec<ResolvedIntercept>,
    pub intercept_broker: Option<InterceptBrokerPlan>,
    pub environment_default: EnvDefault,
    pub allowed_environment_patterns: Vec<String>,
    pub environment: BTreeMap<String, String>,
    pub removed_environment_keys: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SandboxCheck {
    pub valid: bool,
    pub paths: ResolvedConfigPaths,
    pub sources: Vec<ExplainedSource>,
    pub infos: Vec<String>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SandboxExecutionPlan {
    pub context: BTreeMap<String, String>,
    pub paths: ResolvedConfigPaths,
    pub sources: Vec<ExplainedSource>,
    pub protected_sandbox_files: Vec<PathBuf>,
    pub infos: Vec<String>,
    pub warnings: Vec<String>,
    pub policy: EffectiveSandboxPolicy,
    pub intercepts: Vec<ResolvedIntercept>,
    pub intercept_broker: Option<InterceptBrokerPlan>,
    pub environment_default: EnvDefault,
    pub allowed_environment_patterns: Vec<String>,
    pub environment: BTreeMap<String, String>,
    pub removed_environment_keys: Vec<String>,
}

#[derive(Debug, Error)]
pub enum SandboxError {
    #[error("failed to read Sandboxfile at {path}: {source}")]
    Read { path: PathBuf, source: io::Error },
    #[error("failed to write Sandboxfile at {path}: {source}")]
    Write { path: PathBuf, source: io::Error },
    #[error("failed to parse sandbox source {input}:{line}: {message}")]
    Parse {
        input: String,
        line: usize,
        message: String,
    },
    #[error("unsupported Sandboxfile version: {0}")]
    UnsupportedVersion(u32),
    #[error("repository Sandboxfile operations require a repository root")]
    MissingRepoRoot,
    #[error("could not determine HOME for Sandboxfile resolution")]
    MissingHome,
    #[error("found multiple Sandboxfiles in {directory}: {paths:?}")]
    MultipleDirectorySandboxfiles {
        directory: PathBuf,
        paths: Vec<PathBuf>,
    },
    #[error("undefined variable ${name} in {origin}:{line}")]
    UndefinedVariable {
        name: String,
        origin: String,
        line: usize,
    },
    #[error("invalid path in {origin}:{line}: {message}")]
    InvalidPath {
        origin: String,
        line: usize,
        message: String,
    },
    #[error("invalid Sandboxfile control flow in {origin}:{line}: {message}")]
    ControlFlow {
        origin: String,
        line: usize,
        message: String,
    },
    #[error("unknown builtin module: {0}")]
    UnknownBuiltin(String),
    #[error("recursive builtin use detected: {stack:?}")]
    RecursiveBuiltin { stack: Vec<String> },
    #[error("recursive Sandboxfile include detected: {stack:?}")]
    RecursiveInclude { stack: Vec<PathBuf> },
    #[error("invalid intercept command name: {0}")]
    InvalidInterceptCommand(String),
    #[error("could not resolve command `{command}` from PATH in {origin}:{line}")]
    CommandNotFound {
        command: String,
        origin: String,
        line: usize,
    },
    #[error("primary command is not permitted by the current sandbox policy: {0}")]
    PrimaryCommandDenied(String),
    #[error("invalid network rule in {origin}:{line}: {message}")]
    InvalidNetwork {
        origin: String,
        line: usize,
        message: String,
    },
    #[error("invalid --write-root {path}: {message}")]
    InvalidWriteRoot { path: PathBuf, message: String },
    #[error("failed to resolve the current executable for intercept shims: {0}")]
    CurrentExecutable(io::Error),
    #[error("failed to prepare intercept runtime at {path}: {source}")]
    ShimIo { path: PathBuf, source: io::Error },
    #[error("sandboxing is not supported on this platform")]
    UnsupportedPlatform,
    #[error("failed to apply macOS sandbox: {0}")]
    MacOsApi(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PathKind {
    File,
    Root,
}

#[derive(Debug, Clone)]
struct ResolvedPathValue {
    path: PathBuf,
    aliases: Vec<PathBuf>,
    kind: PathKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PendingIntercept {
    command_name: String,
    handler: PendingInterceptHandler,
    source_name: String,
    line_number: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum PendingInterceptHandler {
    File { path: PathBuf },
    InlineScript { source: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PendingExecCommand {
    command_name: String,
    source_name: String,
    line_number: usize,
}

#[derive(Debug, Clone)]
struct SourceFile {
    kind: SourceFileKind,
    name: String,
    path: Option<PathBuf>,
    base_dir: PathBuf,
    source: String,
    program: ParsedProgram,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SourceFileKind {
    Config,
    Builtin,
    Include,
}

#[derive(Debug, Clone)]
struct EvaluationState {
    vars: BTreeMap<String, String>,
    policy: EffectiveSandboxPolicy,
    sources: Vec<ExplainedSource>,
    protected_sandbox_files: Vec<PathBuf>,
    infos: Vec<String>,
    warnings: Vec<String>,
    pending_exec_commands: Vec<PendingExecCommand>,
    pending_intercepts: Vec<PendingIntercept>,
    environment_default: EnvDefault,
    allowed_environment_patterns: Vec<String>,
    environment_overrides: BTreeMap<String, String>,
    removed_environment_keys: Vec<String>,
    builtin_stack: Vec<String>,
    include_stack: Vec<PathBuf>,
}

#[derive(Debug, Clone)]
enum ControlFrame {
    If {
        parent_active: bool,
        condition: bool,
        taking_else: bool,
    },
    Switch {
        parent_active: bool,
        switch_value: String,
        matched: bool,
        active_case: bool,
        saw_default: bool,
    },
}

impl Default for EffectiveSandboxPolicy {
    fn default() -> Self {
        Self {
            fs_default: FsDefault::None,
            exec_default: ExecDefault::Deny,
            net_default: NetDefault::None,
            readable_paths: Vec::new(),
            readable_roots: Vec::new(),
            writable_paths: Vec::new(),
            writable_roots: Vec::new(),
            executable_paths: Vec::new(),
            executable_roots: Vec::new(),
            denied_readable_paths: Vec::new(),
            denied_readable_roots: Vec::new(),
            denied_writable_paths: Vec::new(),
            denied_writable_roots: Vec::new(),
            denied_executable_paths: Vec::new(),
            denied_executable_roots: Vec::new(),
            local_socket_paths: Vec::new(),
            proxied_hosts: Vec::new(),
            connect_rules: Vec::new(),
        }
    }
}

impl SandboxContext {
    pub fn from_process_environment(current_dir: PathBuf) -> Self {
        let env = std::env::vars().collect::<BTreeMap<_, _>>();
        let shell_path = env
            .get("SHELL")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let shell = shell_path
            .as_ref()
            .and_then(|path| basename(path))
            .map(str::to_owned);

        Self {
            repo_root: Some(current_dir.clone()),
            current_dir,
            launch: LaunchKind::Command,
            interactive: false,
            shell,
            shell_path,
            agent: None,
            session_dir: None,
            argv: Vec::new(),
            env,
        }
    }
}

impl SandboxExecutionPlan {
    pub fn check(&self) -> SandboxCheck {
        SandboxCheck {
            valid: true,
            paths: self.paths.clone(),
            sources: self.sources.clone(),
            infos: self.infos.clone(),
            warnings: self.warnings.clone(),
        }
    }

    pub fn explain(&self) -> SandboxExplain {
        SandboxExplain {
            context: self.context.clone(),
            paths: self.paths.clone(),
            sources: self.sources.clone(),
            protected_sandbox_files: self.protected_sandbox_files.clone(),
            infos: self.infos.clone(),
            warnings: self.warnings.clone(),
            policy: self.policy.clone(),
            intercepts: self.intercepts.clone(),
            intercept_broker: self.intercept_broker.clone(),
            environment_default: self.environment_default,
            allowed_environment_patterns: self.allowed_environment_patterns.clone(),
            environment: self.environment.clone(),
            removed_environment_keys: self.removed_environment_keys.clone(),
        }
    }
}

pub fn list_builtin_names() -> Vec<String> {
    builtins::names().into_iter().map(str::to_string).collect()
}

pub fn builtin_preview(
    request: &str,
    context: &SandboxContext,
) -> Result<BuiltinPreview, SandboxError> {
    let vars = seed_variables(context)?;
    let resolved_name = resolve_builtin_request(request);
    let base_dir = context
        .repo_root
        .clone()
        .unwrap_or_else(|| context.current_dir.clone());
    let source_file = load_builtin_source(&resolved_name, base_dir)?;
    let mut state = EvaluationState {
        vars,
        policy: EffectiveSandboxPolicy::default(),
        sources: Vec::new(),
        protected_sandbox_files: Vec::new(),
        infos: Vec::new(),
        warnings: Vec::new(),
        pending_exec_commands: Vec::new(),
        pending_intercepts: Vec::new(),
        environment_default: EnvDefault::None,
        allowed_environment_patterns: Vec::new(),
        environment_overrides: BTreeMap::new(),
        removed_environment_keys: Vec::new(),
        builtin_stack: Vec::new(),
        include_stack: Vec::new(),
    };
    evaluate_source(&mut state, context, &source_file)?;

    Ok(BuiltinPreview {
        requested_name: request.to_string(),
        resolved_name: Some(resolved_name),
        source: Some(source_file.source.clone()),
        infos: state.infos,
        warnings: state.warnings,
    })
}

pub fn resolved_config_paths(start_dir: &Path) -> Result<ResolvedConfigPaths, SandboxError> {
    resolved_config_paths_with_init(start_dir, Some(start_dir))
}

pub fn ensure_sandboxfile(context: &SandboxContext) -> Result<SandboxInitResult, SandboxError> {
    let paths = resolved_config_paths_for_context(context)?;
    if let Some(path) = paths.existing_paths.first().cloned() {
        return Ok(SandboxInitResult {
            path,
            created: false,
        });
    }

    let path = paths
        .init_path
        .clone()
        .ok_or(SandboxError::MissingRepoRoot)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| SandboxError::Write {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    let mut file = match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(file) => file,
        Err(source) if source.kind() == io::ErrorKind::AlreadyExists => {
            return Ok(SandboxInitResult {
                path,
                created: false,
            });
        }
        Err(source) => {
            return Err(SandboxError::Write {
                path: path.clone(),
                source,
            });
        }
    };
    if let Err(source) = file.write_all(default_sandboxfile_template().as_bytes()) {
        let _ = fs::remove_file(&path);
        return Err(SandboxError::Write {
            path: path.clone(),
            source,
        });
    }
    if let Err(source) = file.flush() {
        let _ = fs::remove_file(&path);
        return Err(SandboxError::Write {
            path: path.clone(),
            source,
        });
    }

    Ok(SandboxInitResult {
        path,
        created: true,
    })
}

pub fn check(
    context: &SandboxContext,
    extra_write_roots: &[PathBuf],
) -> Result<SandboxCheck, SandboxError> {
    Ok(build_execution_plan(context, extra_write_roots)?.check())
}

pub fn explain(
    context: &SandboxContext,
    extra_write_roots: &[PathBuf],
) -> Result<SandboxExplain, SandboxError> {
    Ok(build_execution_plan(context, extra_write_roots)?.explain())
}

pub fn build_execution_plan(
    context: &SandboxContext,
    extra_write_roots: &[PathBuf],
) -> Result<SandboxExecutionPlan, SandboxError> {
    let paths = resolved_config_paths_for_context(context)?;
    let mut state = EvaluationState {
        vars: seed_variables(context)?,
        policy: EffectiveSandboxPolicy::default(),
        sources: Vec::new(),
        protected_sandbox_files: Vec::new(),
        infos: Vec::new(),
        warnings: Vec::new(),
        pending_exec_commands: Vec::new(),
        pending_intercepts: Vec::new(),
        environment_default: EnvDefault::None,
        allowed_environment_patterns: Vec::new(),
        environment_overrides: BTreeMap::new(),
        removed_environment_keys: Vec::new(),
        builtin_stack: Vec::new(),
        include_stack: Vec::new(),
    };

    for source in load_config_sources(&paths)? {
        evaluate_source(&mut state, context, &source)?;
    }

    for root in extra_write_roots {
        if !root.is_dir() {
            return Err(SandboxError::InvalidWriteRoot {
                path: root.clone(),
                message: "write roots must already exist and be directories".to_string(),
            });
        }
        add_fs_allowance(
            &mut state.policy,
            FsAccess::Write,
            &normalize_absolute_path(root.clone()),
            PathKind::Root,
        );
    }

    resolve_pending_exec_commands(&mut state, context)?;
    let mut intercepts = resolve_pending_intercepts(&mut state, context)?;
    let (intercept_environment, intercept_broker) =
        prepare_intercept_environment(&mut state.policy, &mut intercepts, context)?;
    for (key, value) in intercept_environment {
        if key == "PATH" {
            state.vars.insert(key.clone(), value.clone());
        }
        state.environment_overrides.insert(key, value);
    }
    protect_loaded_sandboxfiles(&mut state.policy, &state.protected_sandbox_files);
    validate_primary_command(&state.policy, &state.vars, context)?;

    Ok(SandboxExecutionPlan {
        context: state.vars,
        paths,
        sources: state.sources,
        protected_sandbox_files: state.protected_sandbox_files,
        infos: state.infos,
        warnings: state.warnings,
        policy: state.policy,
        intercepts,
        intercept_broker,
        environment_default: state.environment_default,
        allowed_environment_patterns: state.allowed_environment_patterns,
        environment: state.environment_overrides,
        removed_environment_keys: state.removed_environment_keys,
    })
}

pub fn resolved_environment(
    plan: &SandboxExecutionPlan,
    base: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut environment = match plan.environment_default {
        EnvDefault::Inherit => base.clone(),
        EnvDefault::None => {
            let mut environment = BTreeMap::new();
            for (key, value) in base {
                if plan
                    .allowed_environment_patterns
                    .iter()
                    .any(|pattern| environment_name_matches_pattern(pattern, key))
                {
                    environment.insert(key.clone(), value.clone());
                }
            }
            environment
        }
    };

    for key in &plan.removed_environment_keys {
        environment.remove(key);
    }
    for (key, value) in &plan.environment {
        environment.insert(key.clone(), value.clone());
    }

    environment
}

pub fn profile_source(policy: &EffectiveSandboxPolicy) -> String {
    let mut lines = vec![
        "(version 1)".to_string(),
        "(deny default)".to_string(),
        "(import \"system.sb\")".to_string(),
        "(import \"com.apple.corefoundation.sb\")".to_string(),
        "(corefoundation)".to_string(),
        "(system-network)".to_string(),
        "(allow system-audit system-sched mach-task-name process-fork lsopen)".to_string(),
        "(allow process-info* (target self) (target children) (target same-sandbox))".to_string(),
        "(allow signal (target self) (target children) (target same-sandbox))".to_string(),
        "(allow mach-lookup".to_string(),
        "       (global-name \"com.apple.securityd.xpc\")".to_string(),
        "       (global-name \"com.apple.SecurityServer\")".to_string(),
        "       (global-name \"com.apple.TrustEvaluationAgent\")".to_string(),
        "       (global-name \"com.apple.ocspd\"))".to_string(),
        "(allow pseudo-tty)".to_string(),
        "(allow file-read-data file-write-data file-ioctl (literal \"/dev/tty\"))".to_string(),
        "(allow file-read* file-write* file-ioctl (literal \"/dev/ptmx\"))".to_string(),
        "(allow file-read* file-write* file-ioctl (regex \"^/dev/ttys[0-9]*\"))".to_string(),
    ];
    let ancestor_literals = traversal_read_literals(policy);

    if matches!(policy.net_default, NetDefault::Allow) {
        lines.push("(allow network*)".to_string());
        lines.push("(allow network-outbound (remote ip))".to_string());
    }
    if !policy.connect_rules.is_empty() {
        lines.push("(allow network-outbound".to_string());
        for rule in &policy.connect_rules {
            let predicate = match rule.protocol {
                NetProtocol::Tcp => "remote tcp",
                NetProtocol::Udp => "remote udp",
            };
            lines.push(format!(
                "       ({predicate} \"{}\")",
                connect_rule_pattern(rule)
            ));
        }
        lines.push(")".to_string());
    }
    for (index, path) in policy.local_socket_paths.iter().enumerate() {
        let _ = path;
        lines.push(format!(
            "(allow network-outbound (literal (param \"LOCAL_SOCKET_PATH_{index}\")))"
        ));
    }

    match policy.fs_default {
        FsDefault::None => {}
        FsDefault::Read => lines.push("(allow file-read* file-test-existence)".to_string()),
        FsDefault::ReadWrite => {
            lines.push("(allow file-read* file-write* file-test-existence)".to_string())
        }
    }

    if matches!(policy.exec_default, ExecDefault::Allow) {
        lines.push("(allow process-exec process-exec-interpreter file-map-executable)".to_string());
    }

    for (index, path) in ancestor_literals.iter().enumerate() {
        let _ = path;
        lines.push(format!(
            "(allow file-read* file-test-existence (literal (param \"READ_LITERAL_{index}\")))"
        ));
    }
    for (index, path) in policy.readable_paths.iter().enumerate() {
        let _ = path;
        lines.push(format!(
            "(allow file-read* file-test-existence (literal (param \"READ_PATH_{index}\")))"
        ));
    }
    for (index, root) in policy.readable_roots.iter().enumerate() {
        let _ = root;
        lines.push(format!(
            "(allow file-read* file-test-existence (subpath (param \"READ_ROOT_{index}\")))"
        ));
    }
    for (index, path) in policy.writable_paths.iter().enumerate() {
        let _ = path;
        lines.push(format!(
            "(allow file-read* file-write* file-test-existence (literal (param \"WRITE_PATH_{index}\")))"
        ));
    }
    for (index, root) in policy.writable_roots.iter().enumerate() {
        let _ = root;
        lines.push(format!(
            "(allow file-read* file-write* file-test-existence (subpath (param \"WRITE_ROOT_{index}\")))"
        ));
    }
    for (index, path) in policy.executable_paths.iter().enumerate() {
        let _ = path;
        lines.push(format!(
            "(allow file-read* file-test-existence process-exec process-exec-interpreter file-map-executable (literal (param \"EXEC_PATH_{index}\")))"
        ));
    }
    for (index, root) in policy.executable_roots.iter().enumerate() {
        let _ = root;
        lines.push(format!(
            "(allow file-read* file-test-existence process-exec process-exec-interpreter file-map-executable (subpath (param \"EXEC_ROOT_{index}\")))"
        ));
    }
    for (index, path) in policy.denied_readable_paths.iter().enumerate() {
        let _ = path;
        lines.push(format!(
            "(deny file-read* file-test-existence (literal (param \"DENY_READ_PATH_{index}\")))"
        ));
    }
    for (index, root) in policy.denied_readable_roots.iter().enumerate() {
        let _ = root;
        lines.push(format!(
            "(deny file-read* file-test-existence (subpath (param \"DENY_READ_ROOT_{index}\")))"
        ));
    }
    for (index, path) in policy.denied_writable_paths.iter().enumerate() {
        let _ = path;
        lines.push(format!(
            "(deny file-write* (literal (param \"DENY_WRITE_PATH_{index}\")))"
        ));
    }
    for (index, root) in policy.denied_writable_roots.iter().enumerate() {
        let _ = root;
        lines.push(format!(
            "(deny file-write* (subpath (param \"DENY_WRITE_ROOT_{index}\")))"
        ));
    }
    for (index, path) in policy.denied_executable_paths.iter().enumerate() {
        let _ = path;
        lines.push(format!(
            "(deny process-exec process-exec-interpreter file-map-executable (literal (param \"DENY_EXEC_PATH_{index}\")))"
        ));
    }
    for (index, root) in policy.denied_executable_roots.iter().enumerate() {
        let _ = root;
        lines.push(format!(
            "(deny process-exec process-exec-interpreter file-map-executable (subpath (param \"DENY_EXEC_ROOT_{index}\")))"
        ));
    }

    lines.join("\n")
}

pub fn profile_parameters(policy: &EffectiveSandboxPolicy) -> Vec<String> {
    let mut parameters = Vec::new();
    for (index, path) in traversal_read_literals(policy).iter().enumerate() {
        parameters.push(format!("READ_LITERAL_{index}"));
        parameters.push(path.to_string_lossy().into_owned());
    }
    for (index, path) in policy.readable_paths.iter().enumerate() {
        parameters.push(format!("READ_PATH_{index}"));
        parameters.push(path.to_string_lossy().into_owned());
    }
    for (index, root) in policy.readable_roots.iter().enumerate() {
        parameters.push(format!("READ_ROOT_{index}"));
        parameters.push(root.to_string_lossy().into_owned());
    }
    for (index, path) in policy.writable_paths.iter().enumerate() {
        parameters.push(format!("WRITE_PATH_{index}"));
        parameters.push(path.to_string_lossy().into_owned());
    }
    for (index, root) in policy.writable_roots.iter().enumerate() {
        parameters.push(format!("WRITE_ROOT_{index}"));
        parameters.push(root.to_string_lossy().into_owned());
    }
    for (index, path) in policy.executable_paths.iter().enumerate() {
        parameters.push(format!("EXEC_PATH_{index}"));
        parameters.push(path.to_string_lossy().into_owned());
    }
    for (index, root) in policy.executable_roots.iter().enumerate() {
        parameters.push(format!("EXEC_ROOT_{index}"));
        parameters.push(root.to_string_lossy().into_owned());
    }
    for (index, path) in policy.denied_readable_paths.iter().enumerate() {
        parameters.push(format!("DENY_READ_PATH_{index}"));
        parameters.push(path.to_string_lossy().into_owned());
    }
    for (index, root) in policy.denied_readable_roots.iter().enumerate() {
        parameters.push(format!("DENY_READ_ROOT_{index}"));
        parameters.push(root.to_string_lossy().into_owned());
    }
    for (index, path) in policy.denied_writable_paths.iter().enumerate() {
        parameters.push(format!("DENY_WRITE_PATH_{index}"));
        parameters.push(path.to_string_lossy().into_owned());
    }
    for (index, root) in policy.denied_writable_roots.iter().enumerate() {
        parameters.push(format!("DENY_WRITE_ROOT_{index}"));
        parameters.push(root.to_string_lossy().into_owned());
    }
    for (index, path) in policy.denied_executable_paths.iter().enumerate() {
        parameters.push(format!("DENY_EXEC_PATH_{index}"));
        parameters.push(path.to_string_lossy().into_owned());
    }
    for (index, root) in policy.denied_executable_roots.iter().enumerate() {
        parameters.push(format!("DENY_EXEC_ROOT_{index}"));
        parameters.push(root.to_string_lossy().into_owned());
    }
    for (index, path) in policy.local_socket_paths.iter().enumerate() {
        parameters.push(format!("LOCAL_SOCKET_PATH_{index}"));
        parameters.push(path.to_string_lossy().into_owned());
    }
    parameters
}

fn traversal_read_literals(policy: &EffectiveSandboxPolicy) -> Vec<PathBuf> {
    let mut paths = BTreeSet::new();
    for path in &policy.readable_paths {
        collect_ancestor_literals(path.parent(), &mut paths);
    }
    for root in &policy.readable_roots {
        collect_ancestor_literals(root.parent(), &mut paths);
    }
    for path in &policy.writable_paths {
        collect_ancestor_literals(path.parent(), &mut paths);
    }
    for root in &policy.writable_roots {
        collect_ancestor_literals(root.parent(), &mut paths);
    }
    for path in &policy.executable_paths {
        collect_ancestor_literals(path.parent(), &mut paths);
    }
    for root in &policy.executable_roots {
        collect_ancestor_literals(root.parent(), &mut paths);
    }
    paths.into_iter().collect()
}

fn collect_ancestor_literals(mut current: Option<&Path>, paths: &mut BTreeSet<PathBuf>) {
    while let Some(path) = current {
        if path.as_os_str().is_empty() {
            break;
        }
        paths.insert(path.to_path_buf());
        current = path.parent();
    }
}

pub fn apply_current_process(policy: &EffectiveSandboxPolicy) -> Result<(), SandboxError> {
    platform::apply_current_process(policy)
}

#[cfg(any(target_os = "macos", test))]
fn macos_policy_summary(policy: &EffectiveSandboxPolicy) -> String {
    format!(
        "fs_default={:?}, exec_default={:?}, net_default={:?}, read_files={}, read_dirs={}, write_files={}, write_dirs={}, exec_files={}, exec_dirs={}, proxied_hosts={}, connect_rules={}, local_sockets={}",
        policy.fs_default,
        policy.exec_default,
        policy.net_default,
        policy.readable_paths.len(),
        policy.readable_roots.len(),
        policy.writable_paths.len(),
        policy.writable_roots.len(),
        policy.executable_paths.len(),
        policy.executable_roots.len(),
        policy.proxied_hosts.len(),
        policy.connect_rules.len(),
        policy.local_socket_paths.len()
    )
}

#[cfg(any(target_os = "macos", test))]
fn format_macos_api_error(
    policy: &EffectiveSandboxPolicy,
    api_message: &str,
    os_error: Option<&io::Error>,
) -> String {
    let mut parts = Vec::new();
    let mut hints = Vec::new();
    let mut raw_errno = None;
    let trimmed_api_message = api_message.trim();
    if !trimmed_api_message.is_empty() && trimmed_api_message != "unknown sandbox error" {
        parts.push(format!("libsandbox: {trimmed_api_message}"));
    }

    if let Some((code, description)) = os_error.and_then(|error| {
        error
            .raw_os_error()
            .filter(|code| *code != 0)
            .map(|code| (code, error.to_string()))
    }) {
        raw_errno = Some(code);
        parts.push(format!("errno {code}: {description}"));
    }

    if raw_errno == Some(1) || trimmed_api_message == "Operation not permitted" {
        hints.push(
            "the current process may already be sandboxed; macOS sandbox_init cannot apply a second profile"
                .to_string(),
        );
    }

    parts.push(format!("policy: {}", macos_policy_summary(policy)));
    hints.push(
        "run `argon sandbox check` and `argon sandbox explain --json` for details".to_string(),
    );

    let mut message = parts.join("; ");
    for hint in hints {
        message.push_str("\nhint: ");
        message.push_str(&hint);
    }
    message
}

fn load_config_sources(paths: &ResolvedConfigPaths) -> Result<Vec<SourceFile>, SandboxError> {
    let mut sources = Vec::new();
    for entry in &paths.entries {
        let Some(path) = entry.existing_path.as_ref() else {
            continue;
        };
        let base_dir = path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| entry.directory.clone());
        sources.push(load_source(
            SourceFileKind::Config,
            path.display().to_string(),
            Some(path.clone()),
            base_dir,
        )?);
    }
    Ok(sources)
}

fn load_builtin_source(name: &str, base_dir: PathBuf) -> Result<SourceFile, SandboxError> {
    let builtin =
        builtins::find(name).ok_or_else(|| SandboxError::UnknownBuiltin(name.to_string()))?;
    let source = builtin.source.to_string();
    let program = parser::parse_program(&format!("builtin:{name}"), &source)?;
    Ok(SourceFile {
        kind: SourceFileKind::Builtin,
        name: name.to_string(),
        path: None,
        base_dir,
        source,
        program,
    })
}

fn load_include_source(path: PathBuf) -> Result<SourceFile, SandboxError> {
    let base_dir = path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("/"));
    load_source(
        SourceFileKind::Include,
        path.display().to_string(),
        Some(path),
        base_dir,
    )
}

fn load_source(
    kind: SourceFileKind,
    name: String,
    path: Option<PathBuf>,
    base_dir: PathBuf,
) -> Result<SourceFile, SandboxError> {
    let path = path.expect("file-backed sources must have a path");
    let source = fs::read_to_string(&path).map_err(|source| SandboxError::Read {
        path: path.clone(),
        source,
    })?;
    let program = parser::parse_program(path.to_string_lossy().as_ref(), &source)?;
    Ok(SourceFile {
        kind,
        name,
        path: Some(path),
        base_dir,
        source,
        program,
    })
}

fn evaluate_source(
    state: &mut EvaluationState,
    context: &SandboxContext,
    source: &SourceFile,
) -> Result<(), SandboxError> {
    match source.kind {
        SourceFileKind::Builtin => {
            if state.builtin_stack.contains(&source.name) {
                let mut stack = state.builtin_stack.clone();
                stack.push(source.name.clone());
                return Err(SandboxError::RecursiveBuiltin { stack });
            }
            state.builtin_stack.push(source.name.clone());
        }
        SourceFileKind::Config | SourceFileKind::Include => {
            if let Some(path) = source.path.as_ref() {
                if state.include_stack.contains(path) {
                    let mut stack = state.include_stack.clone();
                    stack.push(path.clone());
                    return Err(SandboxError::RecursiveInclude { stack });
                }
                state.include_stack.push(path.clone());
            }
        }
    }

    let result = (|| {
        if matches!(
            source.kind,
            SourceFileKind::Config | SourceFileKind::Include
        ) && let Some(path) = source.path.as_ref()
        {
            push_unique_path(&mut state.protected_sandbox_files, path.clone());
        }
        state.sources.push(ExplainedSource {
            kind: match source.kind {
                SourceFileKind::Config => "config".to_string(),
                SourceFileKind::Builtin => "builtin".to_string(),
                SourceFileKind::Include => "include".to_string(),
            },
            name: source.name.clone(),
            path: source.path.clone(),
            source: source.source.clone(),
        });

        let mut control = Vec::<ControlFrame>::new();
        for statement in &source.program.statements {
            match &statement.kind {
                StatementKind::IfTest { args } => {
                    let parent_active = current_active(&control);
                    let condition = if parent_active {
                        evaluate_test(args, &state.vars, source, statement.line_number)?
                    } else {
                        false
                    };
                    control.push(ControlFrame::If {
                        parent_active,
                        condition,
                        taking_else: false,
                    });
                }
                StatementKind::Switch { value } => {
                    let parent_active = current_active(&control);
                    let switch_value = if parent_active {
                        expand_variables_lossy(value, &state.vars)?
                    } else {
                        String::new()
                    };
                    control.push(ControlFrame::Switch {
                        parent_active,
                        switch_value,
                        matched: false,
                        active_case: false,
                        saw_default: false,
                    });
                }
                StatementKind::Case { value } => {
                    let Some(ControlFrame::Switch {
                        parent_active,
                        switch_value,
                        matched,
                        active_case,
                        saw_default,
                    }) = control.last_mut()
                    else {
                        return Err(SandboxError::ControlFlow {
                            origin: source_label(source),
                            line: statement.line_number,
                            message: "CASE without a matching SWITCH".to_string(),
                        });
                    };
                    if *saw_default {
                        return Err(SandboxError::ControlFlow {
                            origin: source_label(source),
                            line: statement.line_number,
                            message: "CASE cannot appear after DEFAULT in the same SWITCH block"
                                .to_string(),
                        });
                    }
                    if !*parent_active || *matched {
                        *active_case = false;
                    } else {
                        let expanded = expand_variables_lossy(value, &state.vars)?;
                        *active_case = expanded == *switch_value;
                        if *active_case {
                            *matched = true;
                        }
                    }
                }
                StatementKind::Default => {
                    let Some(ControlFrame::Switch {
                        parent_active,
                        matched,
                        active_case,
                        saw_default,
                        ..
                    }) = control.last_mut()
                    else {
                        return Err(SandboxError::ControlFlow {
                            origin: source_label(source),
                            line: statement.line_number,
                            message: "DEFAULT without a matching SWITCH".to_string(),
                        });
                    };
                    if *saw_default {
                        return Err(SandboxError::ControlFlow {
                            origin: source_label(source),
                            line: statement.line_number,
                            message: "duplicate DEFAULT in the same SWITCH block".to_string(),
                        });
                    }
                    *saw_default = true;
                    *active_case = *parent_active && !*matched;
                    *matched = true;
                }
                StatementKind::Else => {
                    let Some(ControlFrame::If { taking_else, .. }) = control.last_mut() else {
                        return Err(SandboxError::ControlFlow {
                            origin: source_label(source),
                            line: statement.line_number,
                            message: "ELSE without a matching IF".to_string(),
                        });
                    };
                    if *taking_else {
                        return Err(SandboxError::ControlFlow {
                            origin: source_label(source),
                            line: statement.line_number,
                            message: "duplicate ELSE in the same IF block".to_string(),
                        });
                    }
                    *taking_else = true;
                }
                StatementKind::End => {
                    if control.pop().is_none() {
                        return Err(SandboxError::ControlFlow {
                            origin: source_label(source),
                            line: statement.line_number,
                            message: "END without a matching IF or SWITCH".to_string(),
                        });
                    }
                }
                _ if !current_active(&control) => {}
                StatementKind::Version(version) => {
                    if *version != 1 {
                        return Err(SandboxError::UnsupportedVersion(*version));
                    }
                }
                StatementKind::Set { name, value } => {
                    let expanded = expand_variables(
                        value,
                        &state.vars,
                        &source_label(source),
                        statement.line_number,
                    )?;
                    state.vars.insert(name.clone(), expanded);
                }
                StatementKind::Use { module } => {
                    let expanded = expand_variables(
                        module,
                        &state.vars,
                        &source_label(source),
                        statement.line_number,
                    )?;
                    if is_include_path(&expanded) {
                        let include_path = normalize_absolute_path(resolve_relative_path(
                            Path::new(&expanded),
                            &source.base_dir,
                        ));
                        let include = load_include_source(include_path)?;
                        evaluate_source(state, context, &include)?;
                    } else {
                        let name = resolve_builtin_request(&expanded);
                        let base_dir = context
                            .repo_root
                            .clone()
                            .unwrap_or_else(|| context.current_dir.clone());
                        let builtin = load_builtin_source(&name, base_dir)?;
                        evaluate_source(state, context, &builtin)?;
                    }
                }
                StatementKind::Warn { message } => {
                    let expanded = expand_variables(
                        message,
                        &state.vars,
                        &source_label(source),
                        statement.line_number,
                    )?;
                    state.warnings.push(expanded);
                }
                StatementKind::Info { message } => {
                    let expanded = expand_variables(
                        message,
                        &state.vars,
                        &source_label(source),
                        statement.line_number,
                    )?;
                    state.infos.push(expanded);
                }
                StatementKind::EnvDefault { value } => {
                    state.environment_default = *value;
                }
                StatementKind::EnvAllow { name } => {
                    push_unique_string(&mut state.allowed_environment_patterns, name.clone());
                }
                StatementKind::EnvSet { name, value } => {
                    let expanded = expand_variables(
                        value,
                        &state.vars,
                        &source_label(source),
                        statement.line_number,
                    )?;
                    state.vars.insert(name.clone(), expanded.clone());
                    state.environment_overrides.insert(name.clone(), expanded);
                    state
                        .removed_environment_keys
                        .retain(|candidate| candidate != name);
                }
                StatementKind::EnvUnset { name } => {
                    state.vars.remove(name);
                    state.environment_overrides.remove(name);
                    if !state.removed_environment_keys.contains(name) {
                        state.removed_environment_keys.push(name.clone());
                    }
                }
                StatementKind::FsDefault { value } => {
                    state.policy.fs_default = *value;
                }
                StatementKind::FsAllow { access, value } => {
                    let resolved =
                        resolve_path_value(value, &state.vars, source, statement.line_number)?;
                    validate_fs_allowance(
                        *access,
                        &resolved.path,
                        resolved.kind,
                        source,
                        statement.line_number,
                    )?;
                    add_fs_allowances(&mut state.policy, *access, &resolved.aliases, resolved.kind);
                }
                StatementKind::ExecDefault { value } => {
                    state.policy.exec_default = *value;
                }
                StatementKind::ExecAllow { value } => {
                    let expanded = expand_variables(
                        value,
                        &state.vars,
                        &source_label(source),
                        statement.line_number,
                    )?;
                    if is_path_like(&expanded) {
                        let resolved =
                            resolve_path_value(value, &state.vars, source, statement.line_number)?;
                        validate_exec_allowance(
                            &resolved.path,
                            resolved.kind,
                            source,
                            statement.line_number,
                        )?;
                        add_exec_allowances(&mut state.policy, &resolved.aliases, resolved.kind);
                    } else {
                        state.pending_exec_commands.push(PendingExecCommand {
                            command_name: expanded,
                            source_name: source_label(source),
                            line_number: statement.line_number,
                        });
                    }
                }
                StatementKind::ExecIntercept { command, handler } => {
                    if command.contains('/') || command.is_empty() {
                        return Err(SandboxError::InvalidInterceptCommand(command.clone()));
                    }
                    let handler = match handler {
                        InterceptHandler::Path(handler) => {
                            let resolved = resolve_path_value(
                                handler,
                                &state.vars,
                                source,
                                statement.line_number,
                            )?;
                            if !matches!(resolved.kind, PathKind::File) {
                                return Err(SandboxError::InvalidPath {
                                    origin: source_label(source),
                                    line: statement.line_number,
                                    message: format!(
                                        "intercept handler must be an executable file, not a directory: {}",
                                        resolved.path.display()
                                    ),
                                });
                            }
                            validate_exec_allowance(
                                &resolved.path,
                                resolved.kind,
                                source,
                                statement.line_number,
                            )?;
                            add_exec_allowances(
                                &mut state.policy,
                                &resolved.aliases,
                                resolved.kind,
                            );
                            add_fs_allowances(
                                &mut state.policy,
                                FsAccess::Read,
                                &resolved.aliases,
                                resolved.kind,
                            );
                            add_fs_denials(
                                &mut state.policy,
                                FsAccess::Write,
                                &resolved.aliases,
                                resolved.kind,
                            );
                            PendingInterceptHandler::File {
                                path: resolved.path,
                            }
                        }
                        InterceptHandler::InlineScript { source } => {
                            PendingInterceptHandler::InlineScript {
                                source: source.clone(),
                            }
                        }
                    };
                    state.pending_intercepts.push(PendingIntercept {
                        command_name: command.clone(),
                        handler,
                        source_name: source_label(source),
                        line_number: statement.line_number,
                    });
                }
                StatementKind::NetDefault { value } => {
                    state.policy.net_default = *value;
                }
                StatementKind::NetAllowProxy { value } => {
                    let expanded = expand_variables(
                        value,
                        &state.vars,
                        &source_label(source),
                        statement.line_number,
                    )?;
                    validate_proxy_pattern(&expanded, source, statement.line_number)?;
                    push_unique_string(&mut state.policy.proxied_hosts, expanded);
                }
                StatementKind::NetAllowConnect { protocol, value } => {
                    let expanded = expand_variables(
                        value,
                        &state.vars,
                        &source_label(source),
                        statement.line_number,
                    )?;
                    validate_connect_target(&expanded, source, statement.line_number)?;
                    push_unique_connect_rule(
                        &mut state.policy.connect_rules,
                        NetConnectRule {
                            protocol: *protocol,
                            target: expanded,
                        },
                    );
                }
            }
        }

        if !control.is_empty() {
            return Err(SandboxError::ControlFlow {
                origin: source_label(source),
                line: source
                    .program
                    .statements
                    .last()
                    .map(|statement| statement.line_number)
                    .unwrap_or(1),
                message: "missing END for IF or SWITCH block".to_string(),
            });
        }

        Ok(())
    })();

    match source.kind {
        SourceFileKind::Builtin => {
            let _ = state.builtin_stack.pop();
        }
        SourceFileKind::Config | SourceFileKind::Include => {
            if source.path.is_some() {
                let _ = state.include_stack.pop();
            }
        }
    }

    result
}

fn evaluate_test(
    args: &[String],
    vars: &BTreeMap<String, String>,
    source: &SourceFile,
    line_number: usize,
) -> Result<bool, SandboxError> {
    let expanded = args
        .iter()
        .map(|value| expand_variables_lossy(value, vars))
        .collect::<Result<Vec<_>, _>>()?;

    evaluate_test_tokens(&expanded, source, line_number)
}

fn evaluate_test_tokens(
    args: &[String],
    source: &SourceFile,
    line_number: usize,
) -> Result<bool, SandboxError> {
    if args.is_empty() {
        return Ok(false);
    }
    if args[0] == "!" {
        return Ok(!evaluate_test_tokens(&args[1..], source, line_number)?);
    }

    match args {
        [value] => Ok(!value.is_empty()),
        [operator, value] => match operator.as_str() {
            "-n" => Ok(!value.is_empty()),
            "-z" => Ok(value.is_empty()),
            "-e" => Ok(resolve_test_path(value, source, line_number)?.exists()),
            "-d" => Ok(resolve_test_path(value, source, line_number)?.is_dir()),
            "-f" => Ok(resolve_test_path(value, source, line_number)?.is_file()),
            "-L" => Ok(resolve_test_path(value, source, line_number)?
                .symlink_metadata()
                .map(|metadata| metadata.file_type().is_symlink())
                .unwrap_or(false)),
            _ => Err(SandboxError::Parse {
                input: source_label(source),
                line: line_number,
                message: format!("unsupported TEST unary operator: {operator}"),
            }),
        },
        [left, operator, right] => match operator.as_str() {
            "=" => Ok(left == right),
            "!=" => Ok(left != right),
            _ => Err(SandboxError::Parse {
                input: source_label(source),
                line: line_number,
                message: format!("unsupported TEST binary operator: {operator}"),
            }),
        },
        _ => Err(SandboxError::Parse {
            input: source_label(source),
            line: line_number,
            message: "unsupported TEST expression".to_string(),
        }),
    }
}

fn resolve_pending_exec_commands(
    state: &mut EvaluationState,
    context: &SandboxContext,
) -> Result<(), SandboxError> {
    let path_value = state.vars.get("PATH").cloned().unwrap_or_default();
    for command in std::mem::take(&mut state.pending_exec_commands) {
        let paths = resolve_command_paths_from_path(&command.command_name, &path_value);
        if paths.is_empty() {
            return Err(SandboxError::CommandNotFound {
                command: command.command_name,
                origin: command.source_name,
                line: command.line_number,
            });
        } else {
            for path in paths {
                let aliases = path_aliases(&path);
                add_exec_allowances(&mut state.policy, &aliases, PathKind::File);
                add_fs_allowances(&mut state.policy, FsAccess::Read, &aliases, PathKind::File);
            }
        }
    }

    let explicit_agent = state
        .vars
        .get("AGENT")
        .map(|value| !value.is_empty())
        .unwrap_or(false);
    if context.launch == LaunchKind::Agent && !explicit_agent {
        state
            .warnings
            .push("agent launch requested without an explicit agent family".to_string());
    }

    Ok(())
}

fn resolve_pending_intercepts(
    state: &mut EvaluationState,
    _context: &SandboxContext,
) -> Result<Vec<ResolvedIntercept>, SandboxError> {
    let path_value = state.vars.get("PATH").cloned().unwrap_or_default();
    let mut intercepts = Vec::new();
    let mut seen = HashSet::new();

    for intercept in std::mem::take(&mut state.pending_intercepts) {
        if !seen.insert(intercept.command_name.clone()) {
            state.warnings.push(format!(
                "ignoring duplicate intercept for `{}` from {}:{}",
                intercept.command_name, intercept.source_name, intercept.line_number
            ));
            continue;
        }

        let real_command_path =
            resolve_first_command_from_path(&intercept.command_name, &path_value).ok_or_else(
                || SandboxError::CommandNotFound {
                    command: intercept.command_name.clone(),
                    origin: intercept.source_name.clone(),
                    line: intercept.line_number,
                },
            )?;
        let aliases = path_aliases(&real_command_path);
        add_fs_denials(&mut state.policy, FsAccess::Read, &aliases, PathKind::File);
        add_fs_denials(&mut state.policy, FsAccess::Write, &aliases, PathKind::File);
        add_exec_denials(&mut state.policy, &aliases, PathKind::File);

        let (handler_path, handler_kind, handler_write_protected, inline_script) =
            match intercept.handler {
                PendingInterceptHandler::File { path } => {
                    (path, InterceptHandlerKind::File, true, None)
                }
                PendingInterceptHandler::InlineScript { source } => (
                    PathBuf::new(),
                    InterceptHandlerKind::InlineScript,
                    false,
                    Some(source),
                ),
            };

        intercepts.push(ResolvedIntercept {
            command_name: intercept.command_name,
            handler_path,
            handler_kind,
            handler_write_protected,
            real_command_path: Some(real_command_path),
            shim_path: None,
            exec_helper_path: None,
            inline_script,
        });
    }

    Ok(intercepts)
}

fn prepare_intercept_environment(
    policy: &mut EffectiveSandboxPolicy,
    intercepts: &mut [ResolvedIntercept],
    context: &SandboxContext,
) -> Result<(BTreeMap<String, String>, Option<InterceptBrokerPlan>), SandboxError> {
    if intercepts.is_empty() {
        return Ok((BTreeMap::new(), None));
    }

    let runtime_dir = create_intercept_runtime_dir()?;
    let bin_dir = runtime_dir.join("bin");
    fs::create_dir_all(&bin_dir).map_err(|source| SandboxError::ShimIo {
        path: bin_dir.clone(),
        source,
    })?;

    let current_exe = std::env::current_exe().map_err(SandboxError::CurrentExecutable)?;
    let helper_dir = runtime_dir.join("helpers");
    fs::create_dir_all(&helper_dir).map_err(|source| SandboxError::ShimIo {
        path: helper_dir.clone(),
        source,
    })?;
    let handler_dir = runtime_dir.join("handlers");
    fs::create_dir_all(&handler_dir).map_err(|source| SandboxError::ShimIo {
        path: handler_dir.clone(),
        source,
    })?;
    let info_helper_path =
        copy_intercept_helper(&current_exe, &helper_dir, "argon-intercept-info")?;
    let warn_helper_path =
        copy_intercept_helper(&current_exe, &helper_dir, "argon-intercept-warn")?;
    let error_helper_path =
        copy_intercept_helper(&current_exe, &helper_dir, "argon-intercept-error")?;
    let exec_helper_path =
        copy_intercept_helper(&current_exe, &helper_dir, "argon-intercept-exec")?;
    let legacy_runner_path =
        copy_intercept_helper(&current_exe, &helper_dir, "argon-intercept-run")?;

    let original_path = context
        .env
        .get("PATH")
        .cloned()
        .filter(|value| !value.is_empty());

    let socket_path = runtime_dir.join("broker.sock");
    let token = random_intercept_token();

    for intercept in intercepts.iter_mut() {
        let runtime_handler_path = handler_dir.join(&intercept.command_name);
        if matches!(intercept.handler_kind, InterceptHandlerKind::InlineScript) {
            let source = intercept.inline_script.take().unwrap_or_default();
            fs::write(&runtime_handler_path, source).map_err(|source| SandboxError::ShimIo {
                path: runtime_handler_path.clone(),
                source,
            })?;
            set_executable_permissions(&runtime_handler_path)?;
            add_exec_allowance(policy, &runtime_handler_path, PathKind::File);
            add_fs_allowance(
                policy,
                FsAccess::Read,
                &runtime_handler_path,
                PathKind::File,
            );
            add_fs_denial(
                policy,
                FsAccess::Write,
                &runtime_handler_path,
                PathKind::File,
            );
            intercept.handler_path = runtime_handler_path.clone();
            intercept.handler_write_protected = true;
        } else {
            create_intercept_link(&intercept.handler_path, &runtime_handler_path).map_err(
                |source| SandboxError::ShimIo {
                    path: runtime_handler_path.clone(),
                    source,
                },
            )?;
        }

        let shim_path = bin_dir.join(&intercept.command_name);
        write_intercept_shim(
            &shim_path,
            &intercept.command_name,
            &runtime_handler_path,
            &info_helper_path,
            &warn_helper_path,
            &error_helper_path,
            &exec_helper_path,
            &legacy_runner_path,
            &socket_path,
            &token,
        )?;
        intercept.shim_path = Some(shim_path);
        intercept.exec_helper_path = Some(exec_helper_path.clone());
    }

    add_fs_allowance(policy, FsAccess::Read, &runtime_dir, PathKind::Root);
    add_fs_allowance(policy, FsAccess::Write, &socket_path, PathKind::File);
    push_unique_path(&mut policy.local_socket_paths, socket_path.clone());
    add_exec_allowance(policy, &bin_dir, PathKind::Root);
    add_fs_allowance(policy, FsAccess::Read, &bin_dir, PathKind::Root);
    add_exec_allowance(policy, &helper_dir, PathKind::Root);
    add_fs_allowance(policy, FsAccess::Read, &helper_dir, PathKind::Root);
    add_exec_allowance(policy, &handler_dir, PathKind::Root);
    add_fs_allowance(policy, FsAccess::Read, &handler_dir, PathKind::Root);
    add_fs_denial(policy, FsAccess::Write, &bin_dir, PathKind::Root);
    add_fs_denial(policy, FsAccess::Write, &helper_dir, PathKind::Root);
    add_fs_denial(policy, FsAccess::Write, &handler_dir, PathKind::Root);

    let mut environment = BTreeMap::new();
    environment.insert(
        "PATH".to_string(),
        match original_path.as_ref() {
            Some(path) if !path.is_empty() => {
                format!("{}:{}", runtime_dir.join("bin").display(), path)
            }
            _ => runtime_dir.join("bin").display().to_string(),
        },
    );

    Ok((
        environment,
        Some(InterceptBrokerPlan {
            runtime_dir,
            bin_dir,
            helper_dir,
            info_helper_path,
            warn_helper_path,
            error_helper_path,
            exec_helper_path,
            socket_path,
            token,
            original_path,
        }),
    ))
}

#[cfg(unix)]
fn create_intercept_link(target: &Path, link: &Path) -> io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

#[cfg(not(unix))]
fn create_intercept_link(target: &Path, link: &Path) -> io::Result<()> {
    fs::copy(target, link).map(|_| ())
}

fn copy_intercept_helper(
    current_exe: &Path,
    helper_dir: &Path,
    name: &str,
) -> Result<PathBuf, SandboxError> {
    let path = helper_dir.join(name);
    fs::copy(current_exe, &path).map_err(|source| SandboxError::ShimIo {
        path: path.clone(),
        source,
    })?;
    set_executable_permissions(&path)?;
    Ok(path)
}

#[allow(clippy::too_many_arguments)]
fn write_intercept_shim(
    path: &Path,
    command_name: &str,
    handler_path: &Path,
    info_helper_path: &Path,
    warn_helper_path: &Path,
    error_helper_path: &Path,
    exec_helper_path: &Path,
    legacy_runner_path: &Path,
    socket_path: &Path,
    token: &str,
) -> Result<(), SandboxError> {
    let source = format!(
        "#!/bin/sh\n\
         export {info_env}={info}\n\
         export {warn_env}={warn}\n\
         export {error_env}={error}\n\
         export {exec_env}={exec}\n\
         export {runner_env}={runner}\n\
         export {socket_env}={socket}\n\
         export {token_env}={token}\n\
         export {command_env}={command}\n\
         exec {handler} \"$@\"\n",
        info_env = ARGON_INFO_ENV,
        info = shell_quote(info_helper_path),
        warn_env = ARGON_WARN_ENV,
        warn = shell_quote(warn_helper_path),
        error_env = ARGON_ERROR_ENV,
        error = shell_quote(error_helper_path),
        exec_env = ARGON_EXEC_ENV,
        exec = shell_quote(exec_helper_path),
        runner_env = INTERCEPT_RUNNER_ENV,
        runner = shell_quote(legacy_runner_path),
        socket_env = INTERCEPT_SOCKET_ENV,
        socket = shell_quote(socket_path),
        token_env = INTERCEPT_TOKEN_ENV,
        token = shell_quote(token),
        command_env = INTERCEPT_COMMAND_ENV,
        command = shell_quote(command_name),
        handler = shell_quote(handler_path),
    );
    fs::write(path, source).map_err(|source| SandboxError::ShimIo {
        path: path.to_path_buf(),
        source,
    })?;
    set_executable_permissions(path)
}

fn shell_quote(value: impl AsRef<OsStr>) -> String {
    let value = value.as_ref().to_string_lossy();
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn random_intercept_token() -> String {
    let mut bytes = [0_u8; 32];
    match fs::File::open("/dev/urandom").and_then(|mut file| file.read_exact(&mut bytes)) {
        Ok(()) => {}
        Err(_) => {
            let seed = format!(
                "{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            );
            for (index, byte) in seed.as_bytes().iter().enumerate() {
                bytes[index % bytes.len()] ^= *byte;
            }
        }
    }

    let mut token = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(&mut token, "{byte:02x}");
    }
    token
}

pub fn intercept_inner_policy(
    base_policy: &EffectiveSandboxPolicy,
    intercept: &ResolvedIntercept,
) -> EffectiveSandboxPolicy {
    let mut policy = base_policy.clone();
    let Some(real_command_path) = intercept.real_command_path.as_ref() else {
        return policy;
    };
    let aliases = path_aliases(real_command_path);
    remove_paths(&mut policy.denied_readable_paths, &aliases);
    remove_paths(&mut policy.denied_executable_paths, &aliases);
    policy.local_socket_paths.clear();
    add_fs_allowances(&mut policy, FsAccess::Read, &aliases, PathKind::File);
    add_exec_allowances(&mut policy, &aliases, PathKind::File);
    policy
}

fn remove_paths(paths: &mut Vec<PathBuf>, removals: &[PathBuf]) {
    paths.retain(|path| !removals.contains(path));
}

fn validate_primary_command(
    policy: &EffectiveSandboxPolicy,
    vars: &BTreeMap<String, String>,
    context: &SandboxContext,
) -> Result<(), SandboxError> {
    if !matches!(policy.exec_default, ExecDefault::Deny) {
        return Ok(());
    }
    let Some(primary) = context.argv.first() else {
        return Ok(());
    };

    let resolved = if is_path_like(primary) {
        normalize_absolute_path(resolve_relative_path(
            Path::new(primary),
            context
                .repo_root
                .as_deref()
                .unwrap_or(context.current_dir.as_path()),
        ))
    } else {
        let path_value = vars.get("PATH").cloned().unwrap_or_default();
        resolve_first_command_from_path(primary, &path_value)
            .unwrap_or_else(|| PathBuf::from(primary))
    };

    if path_allowed(
        &resolved,
        &policy.executable_paths,
        &policy.executable_roots,
    ) {
        return Ok(());
    }

    Err(SandboxError::PrimaryCommandDenied(primary.clone()))
}

fn seed_variables(context: &SandboxContext) -> Result<BTreeMap<String, String>, SandboxError> {
    let mut vars = BTreeMap::new();
    for (key, value) in &context.env {
        vars.insert(key.clone(), value.clone());
    }

    let os = current_os_name();
    vars.insert("OS".to_string(), os.to_string());
    vars.insert(
        "LAUNCH".to_string(),
        launch_name(context.launch).to_string(),
    );
    vars.insert(
        "INTERACTIVE".to_string(),
        if context.interactive { "true" } else { "false" }.to_string(),
    );
    vars.insert(
        "CURRENT_DIR".to_string(),
        context.current_dir.display().to_string(),
    );

    if let Some(repo_root) = context.repo_root.as_ref() {
        vars.insert("REPO_ROOT".to_string(), repo_root.display().to_string());
    }
    if let Some(session_dir) = context.session_dir.as_ref() {
        vars.insert("SESSION_DIR".to_string(), session_dir.display().to_string());
    }

    let home = context
        .env
        .get("HOME")
        .filter(|value| !value.is_empty())
        .cloned()
        .ok_or(SandboxError::MissingHome)?;
    vars.insert("HOME".to_string(), home.clone());

    let xdg_config_home = context
        .env
        .get("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .cloned()
        .unwrap_or_else(|| Path::new(&home).join(".config").display().to_string());
    let xdg_cache_home = context
        .env
        .get("XDG_CACHE_HOME")
        .filter(|value| !value.is_empty())
        .cloned()
        .unwrap_or_else(|| Path::new(&home).join(".cache").display().to_string());
    let xdg_state_home = context
        .env
        .get("XDG_STATE_HOME")
        .filter(|value| !value.is_empty())
        .cloned()
        .unwrap_or_else(|| Path::new(&home).join(".local/state").display().to_string());
    let xdg_data_home = context
        .env
        .get("XDG_DATA_HOME")
        .filter(|value| !value.is_empty())
        .cloned()
        .unwrap_or_else(|| Path::new(&home).join(".local/share").display().to_string());

    vars.insert("XDG_CONFIG_HOME".to_string(), xdg_config_home.clone());
    vars.insert("XDG_CACHE_HOME".to_string(), xdg_cache_home.clone());
    vars.insert("XDG_STATE_HOME".to_string(), xdg_state_home.clone());
    vars.insert("XDG_DATA_HOME".to_string(), xdg_data_home.clone());
    vars.insert("USER_CONFIG_HOME".to_string(), xdg_config_home);
    vars.insert(
        "USER_CACHE_HOME".to_string(),
        if os == "macos" {
            Path::new(&home)
                .join("Library/Caches")
                .display()
                .to_string()
        } else {
            xdg_cache_home
        },
    );
    vars.insert(
        "USER_STATE_HOME".to_string(),
        if os == "macos" {
            Path::new(&home)
                .join("Library/Application Support")
                .display()
                .to_string()
        } else {
            xdg_state_home
        },
    );

    let tmpdir = context
        .env
        .get("TMPDIR")
        .filter(|value| !value.is_empty())
        .cloned()
        .unwrap_or_else(|| std::env::temp_dir().display().to_string());
    vars.insert("TMPDIR".to_string(), tmpdir);

    let shell_name = context
        .shell
        .clone()
        .or_else(|| {
            context
                .shell_path
                .as_ref()
                .and_then(|path| basename(path).map(str::to_owned))
        })
        .or_else(|| {
            context
                .env
                .get("SHELL")
                .and_then(|path| basename(Path::new(path)).map(str::to_owned))
        });
    if let Some(shell_name) = shell_name.as_ref() {
        vars.insert("SHELL_NAME".to_string(), shell_name.clone());
    }

    if let Some(agent) = context.agent.as_ref().filter(|value| !value.is_empty()) {
        vars.insert("AGENT".to_string(), agent.clone());
    }

    vars.insert(
        "PATH".to_string(),
        context.env.get("PATH").cloned().unwrap_or_default(),
    );
    vars.insert("ARGC".to_string(), context.argv.len().to_string());
    for (index, value) in context.argv.iter().enumerate() {
        vars.insert(format!("ARGV{index}"), value.clone());
    }
    if let Some(argv0) = context.argv.first() {
        let basename = basename(Path::new(argv0))
            .unwrap_or(argv0.as_str())
            .to_string();
        vars.insert("ARGV0_BASENAME".to_string(), basename);
    }

    Ok(vars)
}

fn resolve_builtin_request(request: &str) -> String {
    request.trim_start_matches("builtin/").to_string()
}

fn default_sandboxfile_template() -> &'static str {
    r#"# This file describes the Argon Sandbox configuration
# Full docs: https://github.com/fiam/argon/blob/main/SANDBOX.md

ENV DEFAULT NONE # Start from a minimal process environment by default.
FS DEFAULT NONE # Start from no filesystem access by default.
EXEC DEFAULT ALLOW # Allow running any command by default.
NET DEFAULT ALLOW # Allow outbound network access by default.
FS ALLOW READ . # Allow reading files inside this repository.
FS ALLOW WRITE . # Allow edits inside this repository.
USE os # Allow access to the operating system's shared filesystem without exposing personal directories.
USE git # Allow git and read standard git configuration files.
USE shell # Allow the current shell binary and shell history when they apply.
USE agent # Load agent-specific config and state when they apply.
IF TEST -f ./Sandboxfile.local # Check for an optional repo-local sandbox extension file.
    USE ./Sandboxfile.local
END
"#
}

fn resolved_config_paths_for_context(
    context: &SandboxContext,
) -> Result<ResolvedConfigPaths, SandboxError> {
    resolved_config_paths_with_init(&context.current_dir, context.repo_root.as_deref())
}

fn resolved_config_paths_with_init(
    start_dir: &Path,
    init_dir: Option<&Path>,
) -> Result<ResolvedConfigPaths, SandboxError> {
    let normalized_start = normalize_absolute_path(start_dir.to_path_buf());
    let mut entries = Vec::new();
    let mut existing_paths = Vec::new();

    for directory in ancestor_directories(&normalized_start) {
        let sandboxfile_path = directory.join(REPO_SANDBOXFILE);
        let dot_sandboxfile_path = directory.join(USER_SANDBOXFILE);
        let compatibility_path = directory.join(USER_SANDBOXFILE_COMPAT);
        let existing = [
            sandboxfile_path.clone(),
            dot_sandboxfile_path.clone(),
            compatibility_path.clone(),
        ]
        .into_iter()
        .filter(|path| path.is_file())
        .collect::<Vec<_>>();

        if existing.len() > 1 {
            return Err(SandboxError::MultipleDirectorySandboxfiles {
                directory: directory.clone(),
                paths: existing,
            });
        }

        let existing_path = existing.into_iter().next();
        if let Some(path) = existing_path.as_ref() {
            existing_paths.push(path.clone());
        }

        entries.push(ResolvedConfigEntry {
            directory,
            sandboxfile_path,
            dot_sandboxfile_path,
            compatibility_path,
            existing_path,
        });
    }

    Ok(ResolvedConfigPaths {
        init_path: init_dir.map(|dir| dir.join(REPO_SANDBOXFILE)),
        entries,
        existing_paths,
    })
}

fn ancestor_directories(start_dir: &Path) -> Vec<PathBuf> {
    let mut directories = Vec::new();
    let mut current = Some(start_dir);
    while let Some(path) = current {
        directories.push(path.to_path_buf());
        current = path.parent();
    }
    directories
}

fn expand_variables(
    input: &str,
    vars: &BTreeMap<String, String>,
    source: &str,
    line: usize,
) -> Result<String, SandboxError> {
    expand_variables_inner(input, vars, Some((source, line)))
}

fn expand_variables_lossy(
    input: &str,
    vars: &BTreeMap<String, String>,
) -> Result<String, SandboxError> {
    expand_variables_inner(input, vars, None)
}

fn expand_variables_inner(
    input: &str,
    vars: &BTreeMap<String, String>,
    strict: Option<(&str, usize)>,
) -> Result<String, SandboxError> {
    let mut output = String::new();
    let mut chars = input.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '$' {
            output.push(ch);
            continue;
        }

        if chars.peek() == Some(&'{') {
            chars.next();
            let mut name = String::new();
            for next in chars.by_ref() {
                if next == '}' {
                    break;
                }
                name.push(next);
            }
            if name.is_empty() {
                if let Some((source, line)) = strict {
                    return Err(SandboxError::UndefinedVariable {
                        name,
                        origin: source.to_string(),
                        line,
                    });
                }
                continue;
            }
            if let Some(value) = vars.get(&name) {
                output.push_str(value);
            } else if let Some((source, line)) = strict {
                return Err(SandboxError::UndefinedVariable {
                    name: name.clone(),
                    origin: source.to_string(),
                    line,
                });
            }
            continue;
        }

        let mut name = String::new();
        while let Some(next) = chars.peek().copied() {
            if next.is_ascii_alphanumeric() || next == '_' {
                name.push(next);
                chars.next();
            } else {
                break;
            }
        }
        if name.is_empty() {
            output.push('$');
            continue;
        }
        if let Some(value) = vars.get(&name) {
            output.push_str(value);
        } else if let Some((source, line)) = strict {
            return Err(SandboxError::UndefinedVariable {
                name: name.clone(),
                origin: source.to_string(),
                line,
            });
        }
    }

    Ok(output)
}

fn resolve_path_value(
    raw: &str,
    vars: &BTreeMap<String, String>,
    source: &SourceFile,
    line_number: usize,
) -> Result<ResolvedPathValue, SandboxError> {
    let source_name = source_label(source);
    let expanded = expand_variables(raw, vars, &source_name, line_number)?;
    if expanded.is_empty() {
        return Err(SandboxError::InvalidPath {
            origin: source_name,
            line: line_number,
            message: "path expands to an empty string".to_string(),
        });
    }

    let forced_root = expanded != "/" && expanded.ends_with('/');
    let trimmed = if forced_root {
        expanded.trim_end_matches('/').to_string()
    } else {
        expanded
    };
    let resolved = resolve_relative_path(Path::new(&trimmed), &source.base_dir);
    let normalized = normalize_absolute_input_path(resolved);
    let kind = if forced_root {
        if !normalized.is_dir() {
            return Err(SandboxError::InvalidPath {
                origin: source_name,
                line: line_number,
                message: format!(
                    "directory path does not exist: {} (guard optional directories with `IF TEST -d ...`)",
                    normalized.display()
                ),
            });
        }
        PathKind::Root
    } else {
        infer_existing_path_kind(&normalized)
    };

    Ok(ResolvedPathValue {
        aliases: path_aliases(&normalized),
        path: normalized,
        kind,
    })
}

fn validate_fs_allowance(
    access: FsAccess,
    path: &Path,
    kind: PathKind,
    source: &SourceFile,
    line_number: usize,
) -> Result<(), SandboxError> {
    match (access, kind) {
        (FsAccess::Read, PathKind::File) => validate_existing_non_directory_path(
            path,
            source,
            line_number,
            "read path does not exist",
            "guard optional files with `IF TEST -f ...`",
        ),
        (FsAccess::Read, PathKind::Root) => validate_existing_directory_path(
            path,
            source,
            line_number,
            "directory path does not exist",
        ),
        (FsAccess::Write, PathKind::File) => validate_writable_file_path(path, source, line_number),
        (FsAccess::Write, PathKind::Root) => validate_existing_directory_path(
            path,
            source,
            line_number,
            "directory path does not exist",
        ),
    }
}

fn validate_exec_allowance(
    path: &Path,
    kind: PathKind,
    source: &SourceFile,
    line_number: usize,
) -> Result<(), SandboxError> {
    match kind {
        PathKind::File => validate_existing_non_directory_path(
            path,
            source,
            line_number,
            "executable path does not exist",
            "guard optional files with `IF TEST -f ...`",
        ),
        PathKind::Root => validate_existing_directory_path(
            path,
            source,
            line_number,
            "executable directory does not exist",
        ),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedConnectTarget {
    address: String,
    port: Option<String>,
}

fn validate_proxy_pattern(
    value: &str,
    source: &SourceFile,
    line_number: usize,
) -> Result<(), SandboxError> {
    if value.is_empty() {
        return Err(SandboxError::InvalidNetwork {
            origin: source_label(source),
            line: line_number,
            message: "proxy host pattern expands to an empty string".to_string(),
        });
    }
    if value.contains("://") || value.contains('/') {
        return Err(SandboxError::InvalidNetwork {
            origin: source_label(source),
            line: line_number,
            message: format!(
                "proxy host patterns must be bare hosts or `*`, not URLs or paths: {value}"
            ),
        });
    }
    if value != "*" && value.contains('*') && !value.starts_with("*.") {
        return Err(SandboxError::InvalidNetwork {
            origin: source_label(source),
            line: line_number,
            message: format!(
                "wildcard proxy host patterns must use the `*.example.com` form: {value}"
            ),
        });
    }
    if value == "*." {
        return Err(SandboxError::InvalidNetwork {
            origin: source_label(source),
            line: line_number,
            message: "proxy host pattern `*.` is invalid".to_string(),
        });
    }
    Ok(())
}

fn validate_connect_target(
    value: &str,
    source: &SourceFile,
    line_number: usize,
) -> Result<(), SandboxError> {
    let parsed = parse_connect_target(value).map_err(|message| SandboxError::InvalidNetwork {
        origin: source_label(source),
        line: line_number,
        message,
    })?;
    if parsed.address == "*" && parsed.port.as_deref() == Some("*") {
        return Err(SandboxError::InvalidNetwork {
            origin: source_label(source),
            line: line_number,
            message: "NET ALLOW CONNECT `*:*` is invalid; use `NET DEFAULT ALLOW` instead"
                .to_string(),
        });
    }
    #[cfg(target_os = "macos")]
    validate_macos_connect_target(&parsed).map_err(|message| SandboxError::InvalidNetwork {
        origin: source_label(source),
        line: line_number,
        message,
    })?;
    Ok(())
}

fn parse_connect_target(value: &str) -> Result<ParsedConnectTarget, String> {
    if value.is_empty() {
        return Err("connect target expands to an empty string".to_string());
    }
    if value == "*" {
        return Err(
            "NET ALLOW CONNECT `*` is invalid; use `*:port` or `NET DEFAULT ALLOW` instead"
                .to_string(),
        );
    }

    let (address, port) = split_connect_target(value)?;
    validate_connect_address(&address)?;
    validate_connect_port(port.as_deref())?;

    Ok(ParsedConnectTarget { address, port })
}

fn split_connect_target(value: &str) -> Result<(String, Option<String>), String> {
    if let Some(stripped) = value.strip_prefix('[') {
        let Some((address, remainder)) = stripped.split_once(']') else {
            return Err(format!("invalid bracketed connect target: {value}"));
        };
        if remainder.is_empty() {
            return Ok((address.to_string(), None));
        }
        let Some(port) = remainder.strip_prefix(':') else {
            return Err(format!("invalid connect target suffix: {value}"));
        };
        return Ok((address.to_string(), Some(port.to_string())));
    }

    if let Some((address, port)) = value.rsplit_once(':') {
        let port_is_valid = port == "*" || port.parse::<u16>().is_ok();
        if port_is_valid && !address.is_empty() && !address.contains(':') {
            return Ok((address.to_string(), Some(port.to_string())));
        }
        if port_is_valid && address.contains('/') {
            return Ok((address.to_string(), Some(port.to_string())));
        }
    }

    Ok((value.to_string(), None))
}

fn validate_connect_address(address: &str) -> Result<(), String> {
    if address == "*" {
        return Ok(());
    }
    if address.eq_ignore_ascii_case("localhost") {
        return Ok(());
    }

    if address.parse::<std::net::IpAddr>().is_ok() {
        return Ok(());
    }

    if let Some((ip, prefix)) = address.split_once('/') {
        let ip = ip
            .parse::<std::net::IpAddr>()
            .map_err(|_| format!("connect target must use an IP, CIDR, or `*`, got `{address}`"))?;
        let prefix = prefix
            .parse::<u8>()
            .map_err(|_| format!("invalid CIDR prefix in connect target `{address}`"))?;
        let max_prefix = match ip {
            std::net::IpAddr::V4(_) => 32,
            std::net::IpAddr::V6(_) => 128,
        };
        if prefix > max_prefix {
            return Err(format!("invalid CIDR prefix in connect target `{address}`"));
        }
        return Ok(());
    }

    Err(format!(
        "connect targets must use an IP, CIDR, or `*`, got `{address}`"
    ))
}

fn validate_connect_port(port: Option<&str>) -> Result<(), String> {
    let Some(port) = port else {
        return Ok(());
    };
    if port == "*" {
        return Ok(());
    }
    port.parse::<u16>()
        .map(|_| ())
        .map_err(|_| format!("invalid port in connect target: {port}"))
}

fn connect_rule_pattern(rule: &NetConnectRule) -> String {
    let parsed = parse_connect_target(&rule.target)
        .expect("validated connect rules should always parse successfully");
    let address = normalize_connect_rule_address(&parsed.address);
    match parsed.port {
        Some(port) => format!("{address}:{port}"),
        None => format!("{address}:*"),
    }
}

#[cfg(target_os = "macos")]
fn validate_macos_connect_target(target: &ParsedConnectTarget) -> Result<(), String> {
    if target.address == "*" {
        return Ok(());
    }

    if target.address.eq_ignore_ascii_case("localhost") {
        return Ok(());
    }

    if let Ok(ip) = target.address.parse::<std::net::IpAddr>()
        && ip.is_loopback()
    {
        return Ok(());
    }

    Err(format!(
        "macOS currently supports NET ALLOW CONNECT only for localhost or `*:port`, not `{}`",
        target.address
    ))
}

fn normalize_connect_rule_address(address: &str) -> String {
    if address.eq_ignore_ascii_case("localhost") {
        return "localhost".to_string();
    }
    if let Ok(ip) = address.parse::<std::net::IpAddr>()
        && ip.is_loopback()
    {
        return "localhost".to_string();
    }
    address.to_string()
}

fn validate_existing_non_directory_path(
    path: &Path,
    source: &SourceFile,
    line_number: usize,
    message: &str,
    hint: &str,
) -> Result<(), SandboxError> {
    if path.exists() && !path.is_dir() {
        return Ok(());
    }

    Err(SandboxError::InvalidPath {
        origin: source_label(source),
        line: line_number,
        message: format!("{message}: {} ({hint})", path.display()),
    })
}

fn validate_existing_directory_path(
    path: &Path,
    source: &SourceFile,
    line_number: usize,
    message: &str,
) -> Result<(), SandboxError> {
    if path.is_dir() {
        return Ok(());
    }

    Err(SandboxError::InvalidPath {
        origin: source_label(source),
        line: line_number,
        message: format!(
            "{message}: {} (guard optional directories with `IF TEST -d ...`)",
            path.display()
        ),
    })
}

fn validate_writable_file_path(
    path: &Path,
    source: &SourceFile,
    line_number: usize,
) -> Result<(), SandboxError> {
    if path.exists() {
        if !path.is_dir() {
            return Ok(());
        }

        return Err(SandboxError::InvalidPath {
            origin: source_label(source),
            line: line_number,
            message: format!("write path refers to a directory: {}", path.display()),
        });
    }

    let Some(parent) = path.parent() else {
        return Err(SandboxError::InvalidPath {
            origin: source_label(source),
            line: line_number,
            message: format!("write path has no parent directory: {}", path.display()),
        });
    };

    if parent.is_dir() {
        return Ok(());
    }

    Err(SandboxError::InvalidPath {
        origin: source_label(source),
        line: line_number,
        message: format!(
            "parent directory does not exist for write path: {} (guard optional directories with `IF TEST -d ...`)",
            path.display()
        ),
    })
}

fn resolve_test_path(
    raw: &str,
    source: &SourceFile,
    line_number: usize,
) -> Result<PathBuf, SandboxError> {
    if raw.is_empty() {
        return Err(SandboxError::InvalidPath {
            origin: source_label(source),
            line: line_number,
            message: "test path expands to an empty string".to_string(),
        });
    }
    Ok(normalize_absolute_path(resolve_relative_path(
        Path::new(raw),
        &source.base_dir,
    )))
}

fn add_fs_allowances(
    policy: &mut EffectiveSandboxPolicy,
    access: FsAccess,
    paths: &[PathBuf],
    kind: PathKind,
) {
    for path in paths {
        add_fs_allowance(policy, access, path, kind);
    }
}

fn add_fs_allowance(
    policy: &mut EffectiveSandboxPolicy,
    access: FsAccess,
    path: &Path,
    kind: PathKind,
) {
    match kind {
        PathKind::File => {
            push_unique_path(&mut policy.readable_paths, path.to_path_buf());
            if matches!(access, FsAccess::Write) {
                push_unique_path(&mut policy.writable_paths, path.to_path_buf());
            }
        }
        PathKind::Root => {
            push_unique_path(&mut policy.readable_roots, path.to_path_buf());
            if matches!(access, FsAccess::Write) {
                push_unique_path(&mut policy.writable_roots, path.to_path_buf());
            }
        }
    }
}

fn protect_loaded_sandboxfiles(policy: &mut EffectiveSandboxPolicy, paths: &[PathBuf]) {
    for path in paths {
        let aliases = path_aliases(path);
        add_fs_denials(policy, FsAccess::Write, &aliases, PathKind::File);
    }
}

fn add_exec_allowances(policy: &mut EffectiveSandboxPolicy, paths: &[PathBuf], kind: PathKind) {
    for path in paths {
        add_exec_allowance(policy, path, kind);
    }
}

fn add_exec_allowance(policy: &mut EffectiveSandboxPolicy, path: &Path, kind: PathKind) {
    match kind {
        PathKind::File => push_unique_path(&mut policy.executable_paths, path.to_path_buf()),
        PathKind::Root => push_unique_path(&mut policy.executable_roots, path.to_path_buf()),
    }
}

fn add_fs_denials(
    policy: &mut EffectiveSandboxPolicy,
    access: FsAccess,
    paths: &[PathBuf],
    kind: PathKind,
) {
    for path in paths {
        add_fs_denial(policy, access, path, kind);
    }
}

fn add_fs_denial(
    policy: &mut EffectiveSandboxPolicy,
    access: FsAccess,
    path: &Path,
    kind: PathKind,
) {
    match (access, kind) {
        (FsAccess::Read, PathKind::File) => {
            push_unique_path(&mut policy.denied_readable_paths, path.to_path_buf())
        }
        (FsAccess::Read, PathKind::Root) => {
            push_unique_path(&mut policy.denied_readable_roots, path.to_path_buf())
        }
        (FsAccess::Write, PathKind::File) => {
            push_unique_path(&mut policy.denied_writable_paths, path.to_path_buf())
        }
        (FsAccess::Write, PathKind::Root) => {
            push_unique_path(&mut policy.denied_writable_roots, path.to_path_buf())
        }
    }
}

fn add_exec_denials(policy: &mut EffectiveSandboxPolicy, paths: &[PathBuf], kind: PathKind) {
    for path in paths {
        add_exec_denial(policy, path, kind);
    }
}

fn add_exec_denial(policy: &mut EffectiveSandboxPolicy, path: &Path, kind: PathKind) {
    match kind {
        PathKind::File => push_unique_path(&mut policy.denied_executable_paths, path.to_path_buf()),
        PathKind::Root => push_unique_path(&mut policy.denied_executable_roots, path.to_path_buf()),
    }
}

fn resolve_command_paths_from_path(command: &str, path_value: &str) -> Vec<PathBuf> {
    let candidate = Path::new(command);
    if candidate.components().count() > 1 {
        return path_aliases(&normalize_absolute_input_path(resolve_relative_path(
            candidate,
            Path::new("."),
        )));
    }

    let mut resolved = Vec::new();
    for root in std::env::split_paths(OsStr::new(path_value)) {
        let candidate = root.join(command);
        if candidate.is_file() {
            let candidate = normalize_absolute_input_path(candidate);
            for path in path_aliases(&candidate) {
                push_unique_path(&mut resolved, path);
            }
        }
    }
    resolved
}

fn resolve_first_command_from_path(command: &str, path_value: &str) -> Option<PathBuf> {
    resolve_command_paths_from_path(command, path_value)
        .into_iter()
        .next()
}

fn create_intercept_runtime_dir() -> Result<PathBuf, SandboxError> {
    #[cfg(unix)]
    let base = PathBuf::from("/tmp").join("argon-sandbox");
    #[cfg(not(unix))]
    let base = std::env::temp_dir().join("argon-sandbox");
    fs::create_dir_all(&base).map_err(|source| SandboxError::ShimIo {
        path: base.clone(),
        source,
    })?;

    for attempt in 0..64_u32 {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let path = base.join(format!("{}-{}-{attempt}", std::process::id(), timestamp));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(normalize_absolute_path(path)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(source) => {
                return Err(SandboxError::ShimIo { path, source });
            }
        }
    }

    Err(SandboxError::ShimIo {
        path: base,
        source: io::Error::new(
            io::ErrorKind::AlreadyExists,
            "could not allocate intercept runtime directory",
        ),
    })
}

#[cfg(unix)]
fn set_executable_permissions(path: &Path) -> Result<(), SandboxError> {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = fs::metadata(path)
        .map_err(|source| SandboxError::ShimIo {
            path: path.to_path_buf(),
            source,
        })?
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).map_err(|source| SandboxError::ShimIo {
        path: path.to_path_buf(),
        source,
    })
}

#[cfg(not(unix))]
fn set_executable_permissions(_path: &Path) -> Result<(), SandboxError> {
    Ok(())
}

fn resolve_relative_path(path: &Path, base_dir: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        base_dir.join(path)
    }
}

fn normalize_absolute_input_path(path: PathBuf) -> PathBuf {
    use std::path::Component;

    let absolute = if path.is_absolute() {
        path
    } else {
        match std::env::current_dir() {
            Ok(current_dir) => current_dir.join(path),
            Err(_) => path,
        }
    };

    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(Path::new("/")),
            Component::CurDir => {}
            Component::ParentDir => {
                let _ = normalized.pop();
            }
            Component::Normal(part) => normalized.push(part),
        }
    }

    if normalized.as_os_str().is_empty() {
        PathBuf::from("/")
    } else {
        normalized
    }
}

fn normalize_absolute_path(path: PathBuf) -> PathBuf {
    fs::canonicalize(&path).unwrap_or(path)
}

fn infer_existing_path_kind(path: &Path) -> PathKind {
    if path.is_dir() {
        PathKind::Root
    } else {
        PathKind::File
    }
}

fn is_path_like(value: &str) -> bool {
    value.contains('/') || value.starts_with('.') || value.starts_with('~')
}

fn is_include_path(value: &str) -> bool {
    Path::new(value).is_absolute()
        || value == "."
        || value == ".."
        || value.starts_with("./")
        || value.starts_with("../")
}

fn environment_name_matches_pattern(pattern: &str, name: &str) -> bool {
    wildcard_match(pattern.as_bytes(), name.as_bytes())
}

fn wildcard_match(pattern: &[u8], value: &[u8]) -> bool {
    let mut pattern_index = 0usize;
    let mut value_index = 0usize;
    let mut star_index = None;
    let mut star_match_index = 0usize;

    while value_index < value.len() {
        if pattern_index < pattern.len()
            && (pattern[pattern_index] == b'?' || pattern[pattern_index] == value[value_index])
        {
            pattern_index += 1;
            value_index += 1;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
            star_index = Some(pattern_index);
            pattern_index += 1;
            star_match_index = value_index;
        } else if let Some(star) = star_index {
            pattern_index = star + 1;
            star_match_index += 1;
            value_index = star_match_index;
        } else {
            return false;
        }
    }

    while pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
        pattern_index += 1;
    }

    pattern_index == pattern.len()
}

fn basename(path: &Path) -> Option<&str> {
    path.file_name().and_then(OsStr::to_str)
}

fn launch_name(launch: LaunchKind) -> &'static str {
    match launch {
        LaunchKind::Command => "command",
        LaunchKind::Shell => "shell",
        LaunchKind::Agent => "agent",
        LaunchKind::Reviewer => "reviewer",
    }
}

fn current_os_name() -> &'static str {
    #[cfg(target_os = "macos")]
    {
        "macos"
    }
    #[cfg(target_os = "linux")]
    {
        "linux"
    }
    #[cfg(target_os = "windows")]
    {
        "windows"
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        "unknown"
    }
}

fn push_unique_path(paths: &mut Vec<PathBuf>, path: PathBuf) {
    if !paths.contains(&path) {
        paths.push(path);
    }
}

fn push_unique_string(values: &mut Vec<String>, value: String) {
    if !values.contains(&value) {
        values.push(value);
    }
}

fn push_unique_connect_rule(values: &mut Vec<NetConnectRule>, value: NetConnectRule) {
    if !values.contains(&value) {
        values.push(value);
    }
}

fn path_aliases(path: &Path) -> Vec<PathBuf> {
    let mut aliases = Vec::new();
    let mut pending = vec![path.to_path_buf()];

    while let Some(candidate) = pending.pop() {
        if aliases.contains(&candidate) {
            continue;
        }
        aliases.push(candidate.clone());

        for expanded in symlink_expanded_paths(&candidate) {
            if !aliases.contains(&expanded) && !pending.contains(&expanded) {
                pending.push(expanded);
            }
        }
    }

    let canonical = normalize_absolute_path(path.to_path_buf());
    if !aliases.contains(&canonical) {
        aliases.push(canonical);
    }
    aliases
}

fn symlink_expanded_paths(path: &Path) -> Vec<PathBuf> {
    let mut expanded = Vec::new();

    for prefix in path_prefixes(path) {
        let Ok(metadata) = fs::symlink_metadata(&prefix) else {
            continue;
        };
        if !metadata.file_type().is_symlink() {
            continue;
        }

        let Ok(target) = fs::read_link(&prefix) else {
            continue;
        };

        let base_dir = prefix.parent().unwrap_or(Path::new("/"));
        let resolved_target =
            normalize_absolute_input_path(resolve_relative_path(&target, base_dir));
        let remainder = path.strip_prefix(&prefix).unwrap_or_else(|_| Path::new(""));
        let rewritten = normalize_absolute_input_path(resolved_target.join(remainder));
        push_unique_path(&mut expanded, rewritten);
    }

    expanded
}

fn path_prefixes(path: &Path) -> Vec<PathBuf> {
    use std::path::Component;

    let mut prefixes = Vec::new();
    let mut current = PathBuf::new();

    for component in path.components() {
        match component {
            Component::Prefix(prefix) => current.push(prefix.as_os_str()),
            Component::RootDir => current.push(Path::new("/")),
            Component::CurDir => {}
            Component::ParentDir => {
                let _ = current.pop();
            }
            Component::Normal(part) => {
                current.push(part);
                prefixes.push(current.clone());
            }
        }
    }

    prefixes
}

fn current_active(control: &[ControlFrame]) -> bool {
    control.iter().all(|frame| match frame {
        ControlFrame::If {
            parent_active,
            condition,
            taking_else,
        } => {
            *parent_active
                && if *taking_else {
                    !*condition
                } else {
                    *condition
                }
        }
        ControlFrame::Switch {
            parent_active,
            active_case,
            ..
        } => *parent_active && *active_case,
    })
}

fn path_allowed(path: &Path, allowed_paths: &[PathBuf], allowed_roots: &[PathBuf]) -> bool {
    if allowed_paths.iter().any(|candidate| candidate == path) {
        return true;
    }

    allowed_roots.iter().any(|root| path.starts_with(root))
}

fn source_label(source: &SourceFile) -> String {
    source
        .path
        .as_ref()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| format!("builtin:{}", source.name))
}

#[cfg(target_os = "macos")]
mod platform {
    use std::ffi::{CStr, CString};
    use std::io;
    use std::os::raw::{c_char, c_int};
    use std::ptr;

    use super::{
        EffectiveSandboxPolicy, SandboxError, format_macos_api_error, profile_parameters,
        profile_source,
    };

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

    pub fn apply_current_process(policy: &EffectiveSandboxPolicy) -> Result<(), SandboxError> {
        let profile = CString::new(profile_source(policy)).map_err(|_| {
            SandboxError::MacOsApi("sandbox profile contains a NUL byte".to_string())
        })?;
        let raw_params = profile_parameters(policy);
        let params = raw_params
            .iter()
            .map(|value| {
                CString::new(value.as_str()).map_err(|_| {
                    SandboxError::MacOsApi("sandbox parameter contains a NUL byte".to_string())
                })
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
        let last_os_error = io::Error::last_os_error();

        if result == 0 {
            return Ok(());
        }

        let api_message = if errorbuf.is_null() {
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

        Err(SandboxError::MacOsApi(format_macos_api_error(
            policy,
            &api_message,
            Some(&last_os_error),
        )))
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::{EffectiveSandboxPolicy, SandboxError};

    pub fn apply_current_process(_policy: &EffectiveSandboxPolicy) -> Result<(), SandboxError> {
        Err(SandboxError::UnsupportedPlatform)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use tempfile::tempdir;

    fn context_for(repo_root: &Path, argv: &[&str]) -> SandboxContext {
        SandboxContext {
            repo_root: Some(repo_root.to_path_buf()),
            current_dir: repo_root.to_path_buf(),
            launch: LaunchKind::Shell,
            interactive: true,
            shell: Some("zsh".to_string()),
            shell_path: Some(PathBuf::from("/bin/zsh")),
            agent: None,
            session_dir: Some(repo_root.join(".argon/sessions")),
            argv: argv.iter().map(|value| value.to_string()).collect(),
            env: BTreeMap::from([
                (
                    "HOME".to_string(),
                    repo_root.join("home").display().to_string(),
                ),
                ("SHELL".to_string(), "/bin/zsh".to_string()),
                ("PATH".to_string(), "/bin:/usr/bin".to_string()),
            ]),
        }
    }

    #[test]
    fn builtins_are_listed() {
        let names = list_builtin_names();
        assert!(names.contains(&"os".to_string()));
        assert!(names.contains(&"git".to_string()));
        assert!(names.contains(&"git/signing".to_string()));
        assert!(names.contains(&"ssh".to_string()));
        assert!(names.contains(&"gpg".to_string()));
        assert!(names.contains(&"shell".to_string()));
        assert!(names.contains(&"agent".to_string()));
        assert!(names.contains(&"os/macos".to_string()));
        assert!(names.contains(&"shell/zsh".to_string()));
    }

    #[cfg(unix)]
    #[test]
    fn path_aliases_expand_parent_and_leaf_symlinks() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path();

        fs::create_dir_all(root.join("real/etc")).expect("real etc");
        fs::create_dir_all(root.join("real/var/run")).expect("real var run");
        symlink("real/etc", root.join("etc")).expect("etc symlink");
        symlink("real/var", root.join("var")).expect("var symlink");
        symlink("../var/run/resolv.conf", root.join("real/etc/resolv.conf"))
            .expect("resolv symlink");
        fs::write(
            root.join("real/var/run/resolv.conf"),
            "nameserver 1.1.1.1\n",
        )
        .expect("resolv");

        let aliases = path_aliases(&root.join("etc/resolv.conf"));

        assert!(
            aliases
                .iter()
                .any(|path| path == &root.join("etc/resolv.conf"))
        );
        assert!(
            aliases
                .iter()
                .any(|path| path == &root.join("real/etc/resolv.conf"))
        );
        assert!(
            aliases
                .iter()
                .any(|path| path == &root.join("var/run/resolv.conf"))
        );
        assert!(
            aliases
                .iter()
                .any(|path| path == &root.join("real/var/run/resolv.conf"))
        );
    }

    #[cfg(unix)]
    #[test]
    fn path_aliases_expand_symlinked_parent_for_missing_leaf() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path();

        fs::create_dir_all(root.join("real/etc")).expect("real etc");
        symlink("real/etc", root.join("etc")).expect("etc symlink");

        let aliases = path_aliases(&root.join("etc/missing.conf"));

        assert!(
            aliases
                .iter()
                .any(|path| path == &root.join("etc/missing.conf"))
        );
        assert!(
            aliases
                .iter()
                .any(|path| path == &root.join("real/etc/missing.conf"))
        );
    }

    #[test]
    fn builtin_preview_warns_for_unknown_shell() {
        let temp = tempdir().expect("tempdir");
        let mut context = context_for(temp.path(), &["/bin/zsh"]);
        context.shell = Some("tcsh".to_string());

        let preview = builtin_preview("shell", &context).expect("preview");
        assert_eq!(preview.resolved_name.as_deref(), Some("shell"));
        assert_eq!(
            preview.warnings,
            vec!["USE shell does not recognize shell `tcsh`"]
        );
    }

    #[test]
    fn builtin_preview_loads_os_dispatch_module() {
        let temp = tempdir().expect("tempdir");
        let context = context_for(temp.path(), &["/bin/zsh"]);

        let preview = builtin_preview("os", &context).expect("preview");
        assert_eq!(preview.resolved_name.as_deref(), Some("os"));
        assert!(preview.warnings.is_empty());
    }

    #[test]
    fn use_os_dispatches_to_platform_module() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "USE os\n").expect("sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context.argv.clear();
        let explain = explain(&context, &[]).expect("explain");

        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "os" && source.kind == "builtin")
        );
        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "os/macos" && source.kind == "builtin")
        );
        assert!(
            explain
                .policy
                .readable_roots
                .iter()
                .any(|path| path == Path::new("/System"))
        );
        assert!(
            explain
                .policy
                .readable_roots
                .iter()
                .any(|path| path == Path::new("/System"))
        );
        assert!(
            explain
                .policy
                .readable_paths
                .iter()
                .any(|path| path == Path::new("/etc/resolv.conf"))
        );
        assert!(
            explain
                .policy
                .readable_paths
                .iter()
                .any(|path| path == Path::new("/private/etc/resolv.conf"))
        );
        assert!(
            explain
                .policy
                .readable_paths
                .iter()
                .any(|path| path == Path::new("/var/run/resolv.conf"))
        );
        assert!(
            explain
                .policy
                .readable_paths
                .iter()
                .any(|path| path == Path::new("/private/var/run/resolv.conf"))
        );
        if Path::new("/opt/homebrew/etc").is_dir() {
            assert!(
                explain
                    .policy
                    .readable_roots
                    .iter()
                    .any(|path| path == Path::new("/opt/homebrew/etc"))
            );
        }
        if Path::new("/usr/local/etc").is_dir() {
            assert!(
                explain
                    .policy
                    .readable_roots
                    .iter()
                    .any(|path| path == Path::new("/usr/local/etc"))
            );
        }
        if Path::new("/Library/Keychains").is_dir() {
            assert!(
                explain
                    .policy
                    .readable_roots
                    .iter()
                    .any(|path| path == Path::new("/Library/Keychains"))
            );
        }
        if Path::new("/Library/Security").is_dir() {
            assert!(
                explain
                    .policy
                    .readable_roots
                    .iter()
                    .any(|path| path == Path::new("/Library/Security"))
            );
        }
        assert!(
            !explain
                .policy
                .readable_paths
                .iter()
                .any(|path| path == Path::new("/usr/local/Cellar"))
        );
        assert!(
            !explain
                .policy
                .readable_roots
                .iter()
                .any(|path| path == Path::new("/usr/local/Cellar"))
        );
        assert!(
            !explain
                .policy
                .executable_paths
                .iter()
                .any(|path| path == Path::new("/usr/local/Cellar"))
        );
        assert!(
            !explain
                .policy
                .executable_roots
                .iter()
                .any(|path| path == Path::new("/usr/local/Cellar"))
        );
    }

    #[test]
    fn use_shell_dispatches_to_shell_specific_module() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "USE shell\n").expect("sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context.argv.clear();
        let explain = explain(&context, &[]).expect("explain");

        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "shell" && source.kind == "builtin")
        );
        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "shell/zsh" && source.kind == "builtin")
        );
        assert!(
            explain
                .policy
                .writable_paths
                .iter()
                .any(|path| path.ends_with(".zsh_history"))
        );
        assert!(
            explain
                .policy
                .writable_paths
                .iter()
                .any(|path| path.ends_with(".zsh_history.LOCK"))
        );
        assert!(
            explain
                .policy
                .writable_paths
                .iter()
                .any(|path| path.ends_with(".zsh_history.new"))
        );
    }

    #[test]
    fn use_shell_does_not_grant_shell_startup_files() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        let zshrc = home.join(".zshrc");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::write(&zshrc, "export DEMO=1\n").expect("zshrc");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "USE shell\n").expect("sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());

        let explain = explain(&context, &[]).expect("explain");
        assert!(!explain.policy.readable_paths.contains(&zshrc));
    }

    #[test]
    fn use_git_allows_git_and_standard_config_files() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        let xdg_config = home.join(".config");
        let bin_root = temp.path().join("bin");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::create_dir_all(xdg_config.join("git")).expect("xdg git");
        fs::create_dir_all(&bin_root).expect("bin");
        fs::write(home.join(".gitconfig"), "[user]\n\tname = Test\n").expect("gitconfig");
        fs::write(
            xdg_config.join("git/config"),
            "[init]\n\tdefaultBranch = main\n",
        )
        .expect("xdg git config");
        fs::write(bin_root.join("git"), "#!/bin/sh\nexit 0\n").expect("fake git");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "USE git\n").expect("sandbox");

        let mut context = context_for(&repo_root, &["git", "status"]);
        context.env.insert(
            "PATH".to_string(),
            format!("{}:/bin:/usr/bin", bin_root.display()),
        );
        context.env.insert(
            "XDG_CONFIG_HOME".to_string(),
            xdg_config.display().to_string(),
        );

        let explain = explain(&context, &[]).expect("explain");

        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "git" && source.kind == "builtin")
        );
        assert!(
            explain
                .policy
                .readable_paths
                .iter()
                .any(|path| path.ends_with(".gitconfig"))
        );
        assert!(
            explain
                .policy
                .readable_roots
                .iter()
                .any(|path| path.ends_with(".config/git"))
        );
        assert!(
            explain
                .policy
                .executable_paths
                .iter()
                .any(|path| path.ends_with("git"))
        );
        assert!(
            explain
                .allowed_environment_patterns
                .iter()
                .any(|pattern| pattern == "GIT_*")
        );
    }

    #[test]
    fn use_git_signing_allows_signing_tools_and_agent_paths() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        let gnupg = home.join(".gnupg");
        let ssh = home.join(".ssh");
        let ssh_auth_sock = ssh.join("agent.sock");
        let ssh_config = ssh.join("config");
        let ssh_allowed_signers = ssh.join("allowed_signers");
        let ssh_private_key = ssh.join("id_ed25519");
        let ssh_public_key = ssh.join("id_ed25519.pub");
        let gpg_conf = gnupg.join("gpg.conf");
        let common_conf = gnupg.join("common.conf");
        let gpg_agent_conf = gnupg.join("gpg-agent.conf");
        let pubring = gnupg.join("pubring.kbx");
        let trustdb = gnupg.join("trustdb.gpg");
        let gpg_agent_socket = gnupg.join("S.gpg-agent");
        let bin_root = temp.path().join("bin");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::create_dir_all(&gnupg).expect("gnupg");
        fs::create_dir_all(&ssh).expect("ssh");
        fs::create_dir_all(&bin_root).expect("bin");
        fs::write(&ssh_config, "Host *\n").expect("ssh config");
        fs::write(&ssh_allowed_signers, "user@example.com ssh-ed25519 AAAA\n")
            .expect("allowed signers");
        fs::write(&ssh_private_key, "PRIVATE KEY\n").expect("ssh private key");
        fs::write(&ssh_public_key, "ssh-ed25519 AAAA test\n").expect("ssh public key");
        fs::write(&gpg_conf, "use-agent\n").expect("gpg conf");
        fs::write(&common_conf, "no-emit-version\n").expect("common conf");
        fs::write(&gpg_agent_conf, "default-cache-ttl 600\n").expect("gpg-agent conf");
        fs::write(&pubring, "PUBRING\n").expect("pubring");
        fs::write(&trustdb, "TRUSTDB\n").expect("trustdb");
        fs::write(bin_root.join("gpg"), "#!/bin/sh\nexit 0\n").expect("fake gpg");
        fs::write(bin_root.join("ssh-keygen"), "#!/bin/sh\nexit 0\n").expect("fake ssh-keygen");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "USE git\nUSE git/signing\n",
        )
        .expect("sandbox");

        let mut context = context_for(&repo_root, &["git", "commit"]);
        context.env.insert(
            "PATH".to_string(),
            format!("{}:/bin:/usr/bin", bin_root.display()),
        );
        context.env.insert(
            "SSH_AUTH_SOCK".to_string(),
            ssh_auth_sock.display().to_string(),
        );

        let explain = explain(&context, &[]).expect("explain");

        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "git/signing" && source.kind == "builtin")
        );
        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "ssh" && source.kind == "builtin")
        );
        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "gpg" && source.kind == "builtin")
        );
        assert!(
            explain
                .policy
                .executable_paths
                .iter()
                .any(|path| path.ends_with("gpg"))
        );
        assert!(
            explain
                .policy
                .executable_paths
                .iter()
                .any(|path| path.ends_with("ssh-keygen"))
        );
        assert!(explain.policy.writable_paths.contains(&ssh_auth_sock));
        assert!(explain.policy.readable_paths.contains(&ssh_config));
        assert!(explain.policy.readable_paths.contains(&ssh_allowed_signers));
        assert!(!explain.policy.readable_paths.contains(&ssh_private_key));
        assert!(!explain.policy.readable_paths.contains(&ssh_public_key));
        assert!(explain.policy.readable_paths.contains(&gpg_conf));
        assert!(explain.policy.readable_paths.contains(&common_conf));
        assert!(explain.policy.readable_paths.contains(&gpg_agent_conf));
        assert!(explain.policy.readable_paths.contains(&pubring));
        assert!(explain.policy.readable_paths.contains(&trustdb));
        assert!(explain.policy.writable_paths.contains(&trustdb));
        assert!(explain.policy.writable_paths.contains(&gpg_agent_socket));
        assert!(!explain.policy.readable_roots.contains(&gnupg));
        assert!(!explain.policy.writable_roots.contains(&gnupg));
        assert!(!explain.policy.readable_roots.contains(&ssh));
        assert!(
            explain
                .allowed_environment_patterns
                .iter()
                .any(|pattern| pattern == "SSH_AUTH_SOCK")
        );
        assert!(
            explain
                .allowed_environment_patterns
                .iter()
                .any(|pattern| pattern == "GNUPGHOME")
        );
        assert!(
            explain
                .allowed_environment_patterns
                .iter()
                .any(|pattern| pattern == "GPG_*")
        );
        assert!(
            explain
                .infos
                .iter()
                .any(|info| info.contains("does not allow SSH private keys"))
        );
    }

    #[test]
    fn net_rules_are_resolved_into_policy_and_profile_parameters() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            r#"
NET DEFAULT NONE
NET ALLOW PROXY api.openai.com
NET ALLOW PROXY *.githubusercontent.com
NET ALLOW CONNECT 127.0.0.1:3000
NET ALLOW CONNECT udp *:53
"#,
        )
        .expect("sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context.argv.clear();
        let explain = explain(&context, &[]).expect("explain");

        assert_eq!(explain.policy.net_default, NetDefault::None);
        assert_eq!(
            explain.policy.proxied_hosts,
            vec![
                "api.openai.com".to_string(),
                "*.githubusercontent.com".to_string()
            ]
        );
        assert_eq!(
            explain.policy.connect_rules,
            vec![
                NetConnectRule {
                    protocol: NetProtocol::Tcp,
                    target: "127.0.0.1:3000".to_string(),
                },
                NetConnectRule {
                    protocol: NetProtocol::Udp,
                    target: "*:53".to_string(),
                }
            ]
        );

        let profile = profile_source(&explain.policy);
        assert!(profile.contains("(allow network-outbound"));
        assert!(profile.contains("(remote tcp \"localhost:3000\")"));
        assert!(profile.contains("(remote udp \"*:53\")"));
    }

    #[test]
    fn net_allow_connect_rejects_hostname_targets() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "NET ALLOW CONNECT api.openai.com:443\n",
        )
        .expect("sandbox");

        let context = context_for(&repo_root, &["/bin/zsh"]);
        let error = explain(&context, &[]).expect_err("hostname connect should fail");
        assert!(matches!(
            error,
            SandboxError::InvalidNetwork { ref message, .. }
            if message.contains("connect targets must use an IP, CIDR, or `*`")
        ));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn net_allow_connect_rejects_non_loopback_ip_targets_on_macos() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "NET ALLOW CONNECT 10.0.0.15:5432\n",
        )
        .expect("sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context.argv.clear();

        let error = explain(&context, &[]).expect_err("non-loopback connect should fail");
        assert!(matches!(
            error,
            SandboxError::InvalidNetwork { ref message, .. }
            if message.contains("macOS currently supports NET ALLOW CONNECT only for localhost or `*:port`")
        ));
    }

    #[test]
    fn use_agent_dispatches_to_agent_specific_module() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let bin_root = temp.path().join("bin");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(&bin_root).expect("bin");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::create_dir_all(repo_root.join("home/.codex")).expect("agent state");
        fs::write(bin_root.join("codex"), "#!/bin/sh\nexit 0\n").expect("fake codex");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "USE agent\n").expect("sandbox");

        let mut context = context_for(&repo_root, &["codex"]);
        context.launch = LaunchKind::Agent;
        context.agent = Some("codex".to_string());
        context.env.insert(
            "PATH".to_string(),
            format!("{}:/bin:/usr/bin", bin_root.display()),
        );

        let explain = explain(&context, &[]).expect("explain");

        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "agent" && source.kind == "builtin")
        );
        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "agent/codex" && source.kind == "builtin")
        );
        assert!(
            explain
                .policy
                .writable_roots
                .iter()
                .any(|path| path.ends_with(".codex"))
        );
    }

    #[test]
    fn use_agent_infers_agent_family_from_argv0_basename() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let bin_root = temp.path().join("bin");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(&bin_root).expect("bin");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::create_dir_all(repo_root.join("home/.codex")).expect("agent state");
        fs::write(bin_root.join("codex"), "#!/bin/sh\nexit 0\n").expect("fake codex");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "USE agent\n").expect("sandbox");

        let argv0 = bin_root.join("codex").display().to_string();
        let mut context = context_for(&repo_root, &[argv0.as_str()]);
        context.launch = LaunchKind::Agent;
        context.agent = None;
        context.env.insert(
            "PATH".to_string(),
            format!("{}:/bin:/usr/bin", bin_root.display()),
        );

        let explain = explain(&context, &[]).expect("explain");

        assert_eq!(explain.context["ARGV0_BASENAME"], "codex");
        assert!(
            explain
                .sources
                .iter()
                .any(|source| source.name == "agent/codex" && source.kind == "builtin")
        );
        assert!(
            explain
                .warnings
                .iter()
                .all(|warning| !warning.contains("without an explicit agent family"))
        );
    }

    #[test]
    fn switch_default_branch_runs_when_no_case_matches() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(repo_root.join("other"), "#!/bin/sh\n").expect("other");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            r#"EXEC ALLOW other
SWITCH "$ARGV0"
CASE "tool"
WARN "matched"
DEFAULT
WARN "defaulted"
END
"#,
        )
        .expect("sandbox");

        let mut context = context_for(&repo_root, &["other"]);
        context.env.insert(
            "PATH".to_string(),
            format!("{}:/bin:/usr/bin", repo_root.display()),
        );
        let explain = explain(&context, &[]).expect("explain");

        assert!(explain.warnings.contains(&"defaulted".to_string()));
        assert!(!explain.warnings.contains(&"matched".to_string()));
    }

    #[test]
    fn switch_treats_missing_variables_as_empty_strings() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "SWITCH \"$UNSET\"\nCASE \"$UNSET\"\nWARN \"defaulted-empty\"\nEND\n",
        )
        .expect("sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context.argv.clear();
        let explain = explain(&context, &[]).expect("explain");

        assert!(explain.warnings.contains(&"defaulted-empty".to_string()));
    }

    #[test]
    fn case_without_switch_is_rejected() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "CASE \"macos\"\n").expect("sandbox");

        let context = context_for(&repo_root, &["/bin/zsh"]);
        let error = explain(&context, &[]).expect_err("control flow error");

        assert!(matches!(
            error,
            SandboxError::ControlFlow { ref message, .. }
            if message == "CASE without a matching SWITCH"
        ));
    }

    #[test]
    fn ensure_sandboxfile_writes_default_template() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        let context = context_for(&repo_root, &["/bin/zsh"]);

        let result = ensure_sandboxfile(&context).expect("init");
        assert!(result.created);
        let contents = fs::read_to_string(result.path).expect("read");
        assert!(contents.contains("# This file describes the Argon Sandbox configuration"));
        assert!(
            contents.contains("# Full docs: https://github.com/fiam/argon/blob/main/SANDBOX.md")
        );
        assert!(contents.contains("NET DEFAULT ALLOW"));
        assert!(contents.contains("USE os"));
        assert!(contents.contains("USE git"));
        assert!(contents.contains("USE shell"));
        assert!(contents.contains("USE agent"));
        assert!(contents.contains("FS ALLOW READ ."));
        assert!(contents.contains("IF TEST -f ./Sandboxfile.local"));
        assert!(contents.contains("USE ./Sandboxfile.local"));
    }

    #[test]
    fn omitted_defaults_are_closed() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "FS ALLOW READ .\n").expect("sandbox");

        let mut context = context_for(&repo_root, &[]);
        context.argv.clear();

        let explain = explain(&context, &[]).expect("explain");
        assert_eq!(explain.policy.fs_default, FsDefault::None);
        assert_eq!(explain.policy.exec_default, ExecDefault::Deny);
        assert_eq!(explain.policy.net_default, NetDefault::None);
        assert_eq!(explain.environment_default, EnvDefault::None);
    }

    #[test]
    fn profile_source_uses_deny_default_with_explicit_fs_defaults() {
        let mut policy = EffectiveSandboxPolicy::default();
        policy.readable_roots.push(PathBuf::from("/tmp/repo"));

        let profile = profile_source(&policy);

        assert!(profile.contains("(deny default)"));
        assert!(profile.contains("(import \"system.sb\")"));
        assert!(profile.contains("(system-network)"));
        assert!(!profile.contains("(allow network*)"));
        assert!(!profile.contains("(allow network-outbound (remote ip))"));
        assert!(profile.contains("(global-name \"com.apple.securityd.xpc\")"));
        assert!(profile.contains("(global-name \"com.apple.SecurityServer\")"));
        assert!(profile.contains("(global-name \"com.apple.TrustEvaluationAgent\")"));
        assert!(profile.contains("(global-name \"com.apple.ocspd\")"));
        assert!(profile.contains("READ_LITERAL_0"));
        assert!(!profile.contains("(allow file-read* file-test-existence)\n"));

        policy.fs_default = FsDefault::Read;
        let read_profile = profile_source(&policy);
        assert!(read_profile.contains("(allow file-read* file-test-existence)"));

        policy.net_default = NetDefault::Allow;
        let network_profile = profile_source(&policy);
        assert!(network_profile.contains("(allow network*)"));
        assert!(network_profile.contains("(allow network-outbound (remote ip))"));
    }

    #[test]
    fn concurrent_ensure_sandboxfile_only_creates_once() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        let context = context_for(&repo_root, &["/bin/zsh"]);
        let context_a = context.clone();
        let context_b = context.clone();

        let thread_a = std::thread::spawn(move || ensure_sandboxfile(&context_a).expect("init a"));
        let thread_b = std::thread::spawn(move || ensure_sandboxfile(&context_b).expect("init b"));

        let result_a = thread_a.join().expect("join a");
        let result_b = thread_b.join().expect("join b");

        assert_ne!(result_a.created, result_b.created);
        let contents = fs::read_to_string(repo_root.join(REPO_SANDBOXFILE)).expect("read");
        assert!(contents.contains("# This file describes the Argon Sandbox configuration"));
        assert!(
            contents.contains("# Full docs: https://github.com/fiam/argon/blob/main/SANDBOX.md")
        );
        assert!(contents.contains("FS ALLOW READ ."));
        assert!(contents.contains("NET DEFAULT ALLOW"));
        assert!(contents.contains("USE git"));
        assert!(contents.contains("IF TEST -f ./Sandboxfile.local"));
    }

    #[test]
    fn repo_and_user_files_merge_in_order() {
        let temp = tempdir().expect("tempdir");
        let home = temp.path().join("home");
        let repo_root = home.join("repo");
        fs::create_dir_all(repo_root.join(".direnv")).expect("repo dir");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "VERSION 1\nFS DEFAULT NONE\nFS ALLOW WRITE .direnv\nEXEC DEFAULT DENY\n",
        )
        .expect("repo sandbox");
        fs::write(
            home.join(USER_SANDBOXFILE),
            "VERSION 1\nFS DEFAULT READ\nEXEC DEFAULT ALLOW\n",
        )
        .expect("user sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());
        context.argv.clear();

        let explain = explain(&context, &[]).expect("explain");
        assert_eq!(explain.policy.fs_default, FsDefault::Read);
        assert_eq!(explain.policy.exec_default, ExecDefault::Allow);
        assert!(
            explain
                .policy
                .writable_roots
                .iter()
                .any(|path| path.ends_with(".direnv"))
        );
    }

    #[test]
    fn compatibility_user_sandboxfile_is_resolved() {
        let temp = tempdir().expect("tempdir");
        let home = temp.path().join("home");
        let repo_root = home.join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            home.join(USER_SANDBOXFILE_COMPAT),
            "VERSION 1\nFS DEFAULT NONE\n",
        )
        .expect("compat sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());

        let paths = resolved_config_paths_for_context(&context).expect("paths");
        assert_eq!(
            paths.existing_paths.first().map(PathBuf::as_path),
            Some(normalize_absolute_path(home.join(USER_SANDBOXFILE_COMPAT)).as_path())
        );
    }

    #[test]
    fn multiple_sandboxfiles_in_the_same_directory_are_rejected() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "FS DEFAULT NONE\n").expect("sandboxfile");
        fs::write(repo_root.join(USER_SANDBOXFILE), "FS DEFAULT READ\n").expect("dot sandboxfile");

        let context = context_for(&repo_root, &["/bin/zsh"]);
        let error = explain(&context, &[]).expect_err("duplicate directory sandboxfiles");

        assert!(matches!(
            error,
            SandboxError::MultipleDirectorySandboxfiles { ref directory, .. }
            if directory == &normalize_absolute_path(repo_root.clone())
        ));
    }

    #[test]
    fn if_test_controls_optional_rules() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "VERSION 1\nIF TEST -n \"$HISTFILE\"\nFS ALLOW WRITE $HISTFILE\nELSE\nFS ALLOW WRITE $HOME/.zsh_history\nEND\n",
        )
        .expect("sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());
        context.argv.clear();

        let explain = explain(&context, &[]).expect("explain");
        assert!(
            explain
                .policy
                .writable_paths
                .iter()
                .any(|path| path.ends_with(".zsh_history"))
        );
    }

    #[test]
    fn zsh_history_helpers_follow_histfile() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        let histfile = home.join(".hist/custom-history");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(histfile.parent().expect("histfile parent")).expect("hist dir");
        fs::create_dir_all(&home).expect("home");
        fs::write(repo_root.join(REPO_SANDBOXFILE), "USE shell\n").expect("sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());
        context
            .env
            .insert("HISTFILE".to_string(), histfile.display().to_string());

        let explain = explain(&context, &[]).expect("explain");
        assert!(explain.policy.writable_paths.contains(&histfile));
        assert!(
            explain
                .policy
                .writable_paths
                .contains(&PathBuf::from(format!("{}.LOCK", histfile.display())))
        );
        assert!(
            explain
                .policy
                .writable_paths
                .contains(&PathBuf::from(format!("{}.new", histfile.display())))
        );
    }

    #[test]
    fn missing_directory_allowances_fail_fast() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "FS ALLOW READ ./missing-dir/\n",
        )
        .expect("sandbox");

        let context = context_for(&repo_root, &["/bin/zsh"]);
        let error = explain(&context, &[]).expect_err("missing directory should fail");

        assert!(matches!(
            error,
            SandboxError::InvalidPath { ref message, .. }
            if message.contains("directory path does not exist")
                && message.contains("IF TEST -d")
        ));
    }

    #[test]
    fn missing_exec_commands_fail_fast() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "EXEC ALLOW missing-tool\n",
        )
        .expect("sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context
            .env
            .insert("PATH".to_string(), "/bin:/usr/bin".to_string());

        let error = explain(&context, &[]).expect_err("missing exec command should fail");
        assert!(matches!(
            error,
            SandboxError::CommandNotFound { ref command, ref origin, line }
            if command == "missing-tool"
                && origin.ends_with("Sandboxfile")
                && line == 1
        ));
    }

    #[test]
    fn missing_write_parent_fails_fast() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "FS ALLOW WRITE ./missing-parent/file.txt\n",
        )
        .expect("sandbox");

        let context = context_for(&repo_root, &["/bin/zsh"]);
        let error = explain(&context, &[]).expect_err("missing write parent should fail");
        assert!(matches!(
            error,
            SandboxError::InvalidPath { ref message, .. }
            if message.contains("parent directory does not exist for write path")
                && message.contains("IF TEST -d")
        ));
    }

    #[test]
    fn format_macos_api_error_includes_errno_and_policy_summary() {
        let mut policy = EffectiveSandboxPolicy::default();
        policy.readable_paths.push(PathBuf::from("/bin/zsh"));
        policy.writable_roots.push(PathBuf::from("/tmp"));
        let error = io::Error::from_raw_os_error(1);

        let message = format_macos_api_error(&policy, "Operation not permitted", Some(&error));

        assert!(message.contains("libsandbox: Operation not permitted"));
        assert!(message.contains("errno 1"));
        assert!(message.contains("\nhint: the current process may already be sandboxed"));
        assert!(message.contains("read_files=1"));
        assert!(message.contains("write_dirs=1"));
        assert!(message.contains("\nhint: run `argon sandbox check`"));
    }

    #[test]
    fn relative_use_loads_local_sandboxfile() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        fs::create_dir_all(repo_root.join(".direnv")).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "IF TEST -f ./Sandboxfile.local\nUSE ./Sandboxfile.local\nEND\n",
        )
        .expect("sandbox");
        fs::write(
            repo_root.join("Sandboxfile.local"),
            "WARN \"loaded-local\"\nFS ALLOW WRITE .direnv\n",
        )
        .expect("local sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());
        context.argv.clear();

        let explain = explain(&context, &[]).expect("explain");
        assert!(
            explain.sources.iter().any(
                |source| source.kind == "include" && source.name.ends_with("Sandboxfile.local")
            )
        );
        assert!(explain.warnings.contains(&"loaded-local".to_string()));
        assert!(
            explain
                .policy
                .writable_roots
                .iter()
                .any(|path| path.ends_with(".direnv"))
        );
    }

    #[test]
    fn loaded_sandboxfiles_are_write_denied_after_allows() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "FS DEFAULT READWRITE\nFS ALLOW WRITE .\nUSE ./Sandboxfile.local\n",
        )
        .expect("sandbox");
        fs::write(repo_root.join("Sandboxfile.local"), "FS ALLOW WRITE .\n")
            .expect("local sandbox");

        let mut context = context_for(&repo_root, &["/bin/zsh"]);
        context.argv.clear();

        let explain = explain(&context, &[]).expect("explain");
        let repo_root = normalize_absolute_path(repo_root);
        let sandboxfile = normalize_absolute_path(repo_root.join(REPO_SANDBOXFILE));
        let local_sandboxfile = normalize_absolute_path(repo_root.join("Sandboxfile.local"));

        assert!(explain.policy.writable_roots.contains(&repo_root));
        assert!(explain.protected_sandbox_files.contains(&sandboxfile));
        assert!(explain.protected_sandbox_files.contains(&local_sandboxfile));
        assert!(explain.policy.denied_writable_paths.contains(&sandboxfile));
        assert!(
            explain
                .policy
                .denied_writable_paths
                .contains(&local_sandboxfile)
        );
    }

    #[test]
    fn recursive_relative_use_is_rejected() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(repo_root.join("home")).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "USE ./Sandboxfile.local\n",
        )
        .expect("sandbox");
        fs::write(
            repo_root.join("Sandboxfile.local"),
            "USE ./Sandboxfile.local\n",
        )
        .expect("local sandbox");

        let context = context_for(&repo_root, &["/bin/zsh"]);
        let error = explain(&context, &[]).expect_err("recursive include");

        assert!(matches!(error, SandboxError::RecursiveInclude { .. }));
    }

    #[test]
    fn argv_variables_are_exposed() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        fs::create_dir_all(repo_root.join(".bin")).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "VERSION 1\nIF TEST \"$ARGV0\" = \"tool\"\nEXEC ALLOW tool\nEND\n",
        )
        .expect("sandbox");
        fs::write(repo_root.join("tool"), "#!/bin/sh\n").expect("tool");

        let mut context = context_for(&repo_root, &["tool", "--help"]);
        context.env.insert(
            "PATH".to_string(),
            format!("{}:/bin:/usr/bin", repo_root.display()),
        );
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());
        context.launch = LaunchKind::Command;
        context.interactive = false;

        let explain = explain(&context, &[]).expect("explain");
        assert_eq!(explain.context["ARGC"], "2");
        assert_eq!(explain.context["ARGV0"], "tool");
        assert_eq!(explain.context["ARGV0_BASENAME"], "tool");
        assert!(
            explain
                .policy
                .executable_paths
                .iter()
                .any(|path| path.ends_with("tool"))
        );
    }

    #[test]
    fn resolved_environment_supports_wildcard_allow_patterns() {
        let plan = SandboxExecutionPlan {
            context: BTreeMap::new(),
            paths: ResolvedConfigPaths {
                init_path: None,
                entries: Vec::new(),
                existing_paths: Vec::new(),
            },
            sources: Vec::new(),
            protected_sandbox_files: Vec::new(),
            infos: Vec::new(),
            warnings: Vec::new(),
            policy: EffectiveSandboxPolicy::default(),
            intercepts: Vec::new(),
            intercept_broker: None,
            environment_default: EnvDefault::None,
            allowed_environment_patterns: vec!["FOO_*".to_string(), "HOME".to_string()],
            environment: BTreeMap::from([("BAR".to_string(), "override".to_string())]),
            removed_environment_keys: vec!["FOO_SECRET".to_string()],
        };
        let base = BTreeMap::from([
            ("HOME".to_string(), "/tmp/home".to_string()),
            ("FOO_VISIBLE".to_string(), "yes".to_string()),
            ("FOO_SECRET".to_string(), "no".to_string()),
            ("BAZ".to_string(), "ignored".to_string()),
        ]);

        let resolved = resolved_environment(&plan, &base);
        assert_eq!(resolved.get("HOME").map(String::as_str), Some("/tmp/home"));
        assert_eq!(resolved.get("FOO_VISIBLE").map(String::as_str), Some("yes"));
        assert!(!resolved.contains_key("FOO_SECRET"));
        assert!(!resolved.contains_key("BAZ"));
        assert_eq!(resolved.get("BAR").map(String::as_str), Some("override"));
    }

    #[test]
    fn bare_exec_allow_resolves_every_matching_path_entry() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        let bin_a = repo_root.join("bin-a");
        let bin_b = repo_root.join("bin-b");
        fs::create_dir_all(&bin_a).expect("bin a");
        fs::create_dir_all(&bin_b).expect("bin b");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            repo_root.join(REPO_SANDBOXFILE),
            "EXEC DEFAULT DENY\nEXEC ALLOW tool\n",
        )
        .expect("sandbox");
        fs::write(bin_a.join("tool"), "#!/bin/sh\n").expect("tool a");
        fs::write(bin_b.join("tool"), "#!/bin/sh\n").expect("tool b");

        let mut context = context_for(&repo_root, &["tool"]);
        context.launch = LaunchKind::Command;
        context.interactive = false;
        context.env.insert(
            "PATH".to_string(),
            format!("{}:{}", bin_a.display(), bin_b.display()),
        );

        let explain = explain(&context, &[]).expect("explain");
        assert!(
            explain
                .policy
                .executable_paths
                .iter()
                .any(|path| path == &normalize_absolute_path(bin_a.join("tool")))
        );
        assert!(
            explain
                .policy
                .executable_paths
                .iter()
                .any(|path| path == &normalize_absolute_path(bin_b.join("tool")))
        );
    }

    #[test]
    fn intercepts_prepare_wrapped_path() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        fs::create_dir_all(repo_root.join(".argon/sandbox/intercepts")).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            repo_root.join("Sandboxfile"),
            "VERSION 1\nEXEC INTERCEPT aws WITH .argon/sandbox/intercepts/aws.sh\n",
        )
        .expect("sandbox");
        fs::write(
            repo_root.join(".argon/sandbox/intercepts/aws.sh"),
            "#!/bin/sh\n",
        )
        .expect("handler");
        fs::write(repo_root.join("aws"), "#!/bin/sh\n").expect("aws");

        let mut context = context_for(&repo_root, &["aws", "sts", "get-caller-identity"]);
        context.env.insert(
            "PATH".to_string(),
            format!("{}:/bin:/usr/bin", repo_root.display()),
        );
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());
        context.launch = LaunchKind::Command;
        context.interactive = false;

        let plan = build_execution_plan(&context, &[]).expect("plan");
        assert_eq!(plan.intercepts.len(), 1);
        assert!(plan.environment.contains_key("PATH"));
        assert!(
            !plan
                .environment
                .contains_key("ARGON_SANDBOX_INTERCEPT_MANIFEST")
        );
        assert!(!plan.environment.contains_key(INTERCEPT_RUNNER_ENV));
        assert!(!plan.environment.contains_key(INTERCEPT_SOCKET_ENV));
        assert!(!plan.environment.contains_key(INTERCEPT_TOKEN_ENV));
        assert!(!plan.environment.contains_key(ARGON_INFO_ENV));
        assert!(!plan.environment.contains_key(ARGON_WARN_ENV));
        assert!(!plan.environment.contains_key(ARGON_ERROR_ENV));
        assert!(!plan.environment.contains_key(ARGON_EXEC_ENV));
        assert!(plan.intercepts[0].shim_path.is_some());
        let broker = plan.intercept_broker.as_ref().expect("broker");
        assert!(broker.info_helper_path.ends_with("argon-intercept-info"));
        assert!(broker.warn_helper_path.ends_with("argon-intercept-warn"));
        assert!(broker.error_helper_path.ends_with("argon-intercept-error"));
        assert!(broker.exec_helper_path.ends_with("argon-intercept-exec"));
        assert_eq!(plan.intercepts[0].handler_kind, InterceptHandlerKind::File);
        assert!(plan.intercepts[0].handler_write_protected);
        assert_eq!(
            plan.intercepts[0].exec_helper_path.as_ref(),
            Some(&broker.exec_helper_path)
        );
        assert!(
            plan.policy
                .denied_writable_paths
                .iter()
                .any(|path| path.ends_with(".argon/sandbox/intercepts/aws.sh"))
        );
        assert!(
            plan.policy
                .denied_readable_paths
                .iter()
                .any(|path| path == &normalize_absolute_path(repo_root.join("aws")))
        );
        assert!(
            plan.policy
                .denied_executable_paths
                .iter()
                .any(|path| path == &normalize_absolute_path(repo_root.join("aws")))
        );
        assert!(
            !plan
                .policy
                .executable_paths
                .iter()
                .any(|path| path == &normalize_absolute_path(repo_root.join("aws")))
        );

        #[cfg(unix)]
        {
            let shim = plan.intercepts[0].shim_path.as_ref().expect("shim");
            assert!(
                std::fs::symlink_metadata(shim)
                    .expect("shim metadata")
                    .file_type()
                    .is_file()
            );
            let shim_source = std::fs::read_to_string(shim).expect("shim source");
            assert!(shim_source.contains("ARGON_EXEC="));
            assert!(shim_source.contains("ARGON_SANDBOX_INTERCEPT_COMMAND='aws'"));
            assert!(shim_source.contains("/handlers/aws"));
            let runtime_handler = broker.runtime_dir.join("handlers/aws");
            assert!(
                std::fs::symlink_metadata(&runtime_handler)
                    .expect("runtime handler metadata")
                    .file_type()
                    .is_symlink()
            );
            assert_eq!(
                std::fs::read_link(runtime_handler).expect("runtime handler target"),
                normalize_absolute_path(repo_root.join(".argon/sandbox/intercepts/aws.sh"))
            );
        }
    }

    #[test]
    fn inline_intercepts_materialize_write_protected_handlers() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        fs::create_dir_all(&repo_root).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            repo_root.join("Sandboxfile"),
            r#"
EXEC INTERCEPT aws WITH SCRIPT <<'ARGON'
#!/bin/sh
exec "$ARGON_EXEC" "$@"
ARGON
"#,
        )
        .expect("sandbox");
        fs::write(repo_root.join("aws"), "#!/bin/sh\n").expect("aws");

        let mut context = context_for(&repo_root, &["aws"]);
        context
            .env
            .insert("PATH".to_string(), repo_root.display().to_string());
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());

        let plan = build_execution_plan(&context, &[]).expect("plan");
        let intercept = plan.intercepts.first().expect("intercept");

        assert_eq!(intercept.handler_kind, InterceptHandlerKind::InlineScript);
        assert!(intercept.handler_write_protected);
        assert!(intercept.handler_path.ends_with("handlers/aws"));
        assert!(
            plan.policy
                .denied_writable_paths
                .iter()
                .any(|path| path == &intercept.handler_path)
        );
        assert_eq!(
            std::fs::read_to_string(&intercept.handler_path).expect("inline handler"),
            "#!/bin/sh\nexec \"$ARGON_EXEC\" \"$@\"\n"
        );
    }

    #[test]
    fn intercept_inner_policy_reallows_real_command_read_and_exec() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        let home = repo_root.join("home");
        fs::create_dir_all(repo_root.join(".argon/sandbox/intercepts")).expect("repo");
        fs::create_dir_all(&home).expect("home");
        fs::write(
            repo_root.join("Sandboxfile"),
            "EXEC INTERCEPT aws WITH .argon/sandbox/intercepts/aws.sh\n",
        )
        .expect("sandbox");
        fs::write(
            repo_root.join(".argon/sandbox/intercepts/aws.sh"),
            "#!/bin/sh\n",
        )
        .expect("handler");
        fs::write(repo_root.join("aws"), "#!/bin/sh\n").expect("aws");

        let mut context = context_for(&repo_root, &["aws"]);
        context
            .env
            .insert("PATH".to_string(), repo_root.display().to_string());
        context
            .env
            .insert("HOME".to_string(), home.display().to_string());

        let plan = build_execution_plan(&context, &[]).expect("plan");
        let intercept = plan.intercepts.first().expect("intercept");
        let real = normalize_absolute_path(repo_root.join("aws"));
        let inner = intercept_inner_policy(&plan.policy, intercept);

        assert!(inner.readable_paths.iter().any(|path| path == &real));
        assert!(inner.executable_paths.iter().any(|path| path == &real));
        assert!(!inner.denied_readable_paths.iter().any(|path| path == &real));
        assert!(
            !inner
                .denied_executable_paths
                .iter()
                .any(|path| path == &real)
        );
        assert!(inner.denied_writable_paths.iter().any(|path| path == &real));
    }
}
