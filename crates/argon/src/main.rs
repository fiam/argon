use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::io::{self, IsTerminal, Read, Write};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

mod sandbox_proxy;

use anyhow::{Context, Result, bail};
use argon_core::{
    AgentEvent, AgentEventKind, CliCommand, CliResponse, CommentAnchor, CommentAuthor, CommentKind,
    PendingFeedback, ResolvedReviewTarget, ReviewComment, ReviewMode, ReviewOutcome, ReviewSession,
    SessionPayload, SessionStatus, SessionStore, StyledSpan, ThreadState,
    auto_detect_review_target, resolve_branch_target, resolve_commit_target,
    resolve_uncommitted_target,
};
use chrono::{DateTime, Utc};
use clap::{Parser, Subcommand, ValueEnum};
use sandbox::{LaunchKind, SandboxContext};
use uuid::Uuid;

#[derive(Parser, Debug)]
#[command(name = "argon", about = "Local PR review loop CLI for agents")]
struct Cli {
    #[arg(long, global = true)]
    desktop_launch: Option<PathBuf>,
    #[arg(long, global = true)]
    repo: Option<PathBuf>,
    #[arg(long, global = true)]
    agent: Option<String>,
    #[arg(long, global = true)]
    sandbox: bool,
    #[arg(long, global = true)]
    description: Option<String>,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Clone, Default)]
struct LaunchOptions {
    desktop_launch: Option<PathBuf>,
    agent_command: Option<String>,
    sandbox_agent: bool,
    change_summary: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct RuntimeOptions {
    launch: LaunchOptions,
    repo_root_override: Option<PathBuf>,
}

#[derive(Debug, Clone)]
struct WorkspaceLaunchTarget {
    repo_root: PathBuf,
    repo_common_dir: PathBuf,
    selected_worktree_root: PathBuf,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Review(ReviewArgs),
    #[command(subcommand)]
    Agent(AgentCommands),
    #[command(subcommand)]
    Sandbox(SandboxCommands),
    #[command(subcommand)]
    Reviewer(ReviewerCommands),
    Diff(DiffArgs),
    #[command(hide = true)]
    Highlight(HighlightArgs),
    #[command(subcommand)]
    Draft(DraftCommands),
    #[command(subcommand)]
    Skill(SkillCommands),
}

#[derive(clap::Args, Debug)]
struct DiffArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long, default_value = "base16-ocean.dark")]
    theme: String,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct HighlightArgs {
    #[arg(long)]
    path: String,
    #[arg(long, default_value = "base16-ocean.dark")]
    theme: String,
    #[arg(long)]
    json: bool,
}

#[derive(serde::Serialize)]
struct HighlightResponse {
    lines: Vec<Vec<StyledSpan>>,
}

#[derive(Subcommand, Debug)]
enum AgentCommands {
    Start(StartArgs),
    Wait(WaitArgs),
    Follow(FollowArgs),
    Status(StatusArgs),
    Close(CloseArgs),
    Reply(ReplyArgs),
    Ack(AckArgs),
    Prompt(PromptArgs),
    #[command(subcommand)]
    Dev(DevCommands),
}

#[derive(Subcommand, Debug)]
enum SandboxCommands {
    /// Inspect resolved Sandboxfile paths.
    #[command(subcommand)]
    Config(SandboxConfigCommands),
    /// Create a default Sandboxfile when none exists.
    Init(SandboxInitArgs),
    /// Inspect builtin Sandboxfile modules.
    #[command(subcommand)]
    Builtin(SandboxBuiltinCommands),
    /// Validate the discovered Sandboxfile stack for the current launch context.
    Check(SandboxCheckArgs),
    /// Resolve and explain the effective sandbox plan.
    Explain(SandboxExplainArgs),
    #[command(hide = true)]
    Seatbelt(SandboxSeatbeltArgs),
    #[command(hide = true)]
    ProxyHelper(SandboxProxyHelperArgs),
    /// Run a command inside Argon's sandbox.
    Exec(SandboxExecArgs),
}

#[derive(Subcommand, Debug)]
enum SandboxConfigCommands {
    /// Print the resolved repo and user sandbox config paths.
    Paths(SandboxConfigPathsArgs),
}

#[derive(Subcommand, Debug)]
enum SandboxBuiltinCommands {
    /// List builtin Sandboxfile modules.
    List(SandboxBuiltinListArgs),
    /// Print a builtin Sandboxfile module.
    Print(SandboxBuiltinPrintArgs),
}

#[derive(Subcommand, Debug)]
enum ReviewerCommands {
    Prompt(ReviewerPromptArgs),
    Wait(ReviewerWaitArgs),
    Comment(ReviewerCommentArgs),
    Decide(ReviewerDecideArgs),
}

#[derive(Subcommand, Debug)]
enum SkillCommands {
    Install(SkillInstallArgs),
}

#[derive(clap::Args, Debug)]
struct SkillInstallArgs {
    #[arg(long, default_value = "all")]
    agent: SkillAgentArg,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum SkillAgentArg {
    ClaudeCode,
    Codex,
    All,
}

#[derive(clap::Args, Debug)]
struct StartArgs {
    #[arg(long)]
    mode: Option<ReviewModeArg>,
    #[arg(long)]
    base: Option<String>,
    #[arg(long)]
    head: Option<String>,
    #[arg(long)]
    wait: bool,
    #[arg(long)]
    json: bool,
    #[arg(long)]
    timeout_secs: Option<u64>,
}

#[derive(clap::Args, Debug)]
struct ReviewArgs {
    path: Option<PathBuf>,
    #[arg(long)]
    base: Option<String>,
    #[arg(long)]
    head: Option<String>,
    #[arg(long)]
    commit: Option<String>,
    #[arg(long)]
    mode: Option<ReviewModeArg>,
    #[arg(long)]
    pr: bool,
    #[arg(long)]
    wait: bool,
    #[arg(long)]
    json: bool,
    #[arg(long)]
    timeout_secs: Option<u64>,
}

#[derive(clap::Args, Debug)]
struct WaitArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    json: bool,
    #[arg(long)]
    timeout_secs: Option<u64>,
}

#[derive(clap::Args, Debug)]
struct FollowArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    jsonl: bool,
}

#[derive(clap::Args, Debug)]
struct StatusArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct CloseArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct ReplyArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    thread: Uuid,
    #[arg(long)]
    message: String,
    #[arg(long)]
    addressed: bool,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct AckArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    thread: Uuid,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct PromptArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    launch: Option<String>,
    #[arg(long)]
    sandbox: bool,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct SandboxExecArgs {
    #[command(flatten)]
    context: SandboxExecutionContextArgs,
    /// Command to run after `--`.
    #[arg(trailing_var_arg = true, required = true, allow_hyphen_values = true)]
    command: Vec<String>,
}

#[derive(clap::Args, Debug)]
struct SandboxExplainArgs {
    #[command(flatten)]
    context: SandboxExecutionContextArgs,
    /// Emit machine-readable JSON.
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct SandboxCheckArgs {
    #[command(flatten)]
    context: SandboxExecutionContextArgs,
    /// Emit machine-readable JSON.
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct SandboxSeatbeltArgs {
    #[command(flatten)]
    context: SandboxExecutionContextArgs,
    /// Emit machine-readable JSON.
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct SandboxProxyHelperArgs {
    #[arg(long)]
    config: PathBuf,
}

#[derive(clap::Args, Debug, Clone)]
struct SandboxExecutionContextArgs {
    /// Repository root used to resolve repo-local Sandboxfile paths.
    #[arg(long)]
    repo_root: Option<PathBuf>,
    /// Writable directory roots whose descendants remain writable.
    #[arg(long = "write-root")]
    write_roots: Vec<PathBuf>,
    /// Launch context used by `USE shell`, `USE agent`, and explain output.
    #[arg(long, value_enum)]
    launch: Option<SandboxLaunchArg>,
    /// Explicit agent family for `USE agent`.
    #[arg(long = "agent-family")]
    agent_family: Option<String>,
    /// Optional session directory to expose in sandbox variables.
    #[arg(long)]
    session_dir: Option<PathBuf>,
    /// Mark the launch as interactive.
    #[arg(long)]
    interactive: bool,
}

#[derive(clap::Args, Debug)]
struct SandboxInitArgs {
    #[arg(long)]
    repo_root: Option<PathBuf>,
    /// Emit machine-readable JSON.
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct SandboxConfigPathsArgs {
    /// Emit machine-readable JSON.
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct SandboxBuiltinListArgs {
    /// Emit machine-readable JSON.
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct SandboxBuiltinPrintArgs {
    name: String,
    #[command(flatten)]
    context: SandboxExecutionContextArgs,
    /// Emit machine-readable JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum SandboxLaunchArg {
    Command,
    Shell,
    Agent,
    Reviewer,
}

#[derive(clap::Args, Debug)]
struct ReviewerPromptArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    reviewer: Option<String>,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct ReviewerWaitArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    reviewer: Option<String>,
    #[arg(long)]
    json: bool,
    #[arg(long)]
    timeout_secs: Option<u64>,
}

#[derive(clap::Args, Debug)]
struct ReviewerCommentArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    reviewer: Option<String>,
    #[arg(long)]
    message: String,
    #[arg(long)]
    thread: Option<Uuid>,
    #[arg(long)]
    file: Option<String>,
    #[arg(long)]
    line_new: Option<u32>,
    #[arg(long)]
    line_old: Option<u32>,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct ReviewerDecideArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    reviewer: Option<String>,
    #[arg(long)]
    outcome: OutcomeArg,
    #[arg(long)]
    summary: Option<String>,
    #[arg(long)]
    json: bool,
}

#[derive(Subcommand, Debug)]
enum DevCommands {
    Comment(DevCommentArgs),
    Decide(DevDecideArgs),
    UpdateTarget(DevUpdateTargetArgs),
    ResolveThread(DevResolveThreadArgs),
}

#[derive(clap::Args, Debug)]
struct DevResolveThreadArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    thread: Uuid,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct DevUpdateTargetArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    mode: ReviewModeArg,
    #[arg(long)]
    base_ref: String,
    #[arg(long)]
    head_ref: String,
    #[arg(long)]
    merge_base_sha: String,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct DevCommentArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    message: String,
    #[arg(long)]
    thread: Option<Uuid>,
    #[arg(long)]
    file: Option<String>,
    #[arg(long)]
    line_new: Option<u32>,
    #[arg(long)]
    line_old: Option<u32>,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct DevDecideArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    outcome: OutcomeArg,
    #[arg(long)]
    summary: Option<String>,
    #[arg(long)]
    json: bool,
}

#[derive(Subcommand, Debug)]
enum DraftCommands {
    Add(DraftAddArgs),
    Delete(DraftDeleteArgs),
    List(DraftListArgs),
    Submit(DraftSubmitArgs),
}

#[derive(clap::Args, Debug)]
struct DraftAddArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    message: String,
    #[arg(long)]
    thread: Option<Uuid>,
    #[arg(long)]
    file: Option<String>,
    #[arg(long)]
    line_new: Option<u32>,
    #[arg(long)]
    line_old: Option<u32>,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct DraftDeleteArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    draft_id: Uuid,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct DraftListArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    json: bool,
}

#[derive(clap::Args, Debug)]
struct DraftSubmitArgs {
    #[arg(long)]
    session: Uuid,
    #[arg(long)]
    outcome: Option<OutcomeArg>,
    #[arg(long)]
    summary: Option<String>,
    #[arg(long)]
    json: bool,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum OutcomeArg {
    Approved,
    ChangesRequested,
    Commented,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum ReviewModeArg {
    Branch,
    Commit,
    Uncommitted,
}

impl From<OutcomeArg> for ReviewOutcome {
    fn from(value: OutcomeArg) -> Self {
        match value {
            OutcomeArg::Approved => ReviewOutcome::Approved,
            OutcomeArg::ChangesRequested => ReviewOutcome::ChangesRequested,
            OutcomeArg::Commented => ReviewOutcome::Commented,
        }
    }
}

impl From<ReviewModeArg> for ReviewMode {
    fn from(value: ReviewModeArg) -> Self {
        match value {
            ReviewModeArg::Branch => ReviewMode::Branch,
            ReviewModeArg::Commit => ReviewMode::Commit,
            ReviewModeArg::Uncommitted => ReviewMode::Uncommitted,
        }
    }
}

impl From<SandboxLaunchArg> for LaunchKind {
    fn from(value: SandboxLaunchArg) -> Self {
        match value {
            SandboxLaunchArg::Command => LaunchKind::Command,
            SandboxLaunchArg::Shell => LaunchKind::Shell,
            SandboxLaunchArg::Agent => LaunchKind::Agent,
            SandboxLaunchArg::Reviewer => LaunchKind::Reviewer,
        }
    }
}

#[derive(Debug, Clone, serde::Serialize)]
struct AgentPromptResponse {
    schema_version: String,
    command: CliCommand,
    session: SessionPayload,
    pending_feedback: Vec<PendingFeedback>,
    continue_command: String,
    prompt: String,
}

#[derive(Debug, Clone, serde::Serialize)]
struct ReviewerPromptResponse {
    schema_version: String,
    command: CliCommand,
    session: SessionPayload,
    reviewer_name: String,
    pending_feedback: Vec<ReviewerFeedback>,
    continue_command: String,
    comment_command_template: String,
    decision_command_template: String,
    prompt: String,
}

#[derive(Debug, Clone, serde::Serialize)]
struct ReviewerFeedback {
    thread_id: Uuid,
    anchor: CommentAnchor,
    latest_author: CommentAuthor,
    latest_author_name: Option<String>,
    latest_comment: String,
    #[serde(skip_serializing)]
    created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct SandboxSeatbeltDebugResponse {
    profile: String,
    parameters: Vec<String>,
    infos: Vec<String>,
    warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AgentWaitSignature {
    decision: Option<argon_core::ReviewDecision>,
    pending_feedback: Vec<(Uuid, Uuid)>,
}

#[derive(Debug, Clone)]
enum WaitResult {
    Ready(ReviewSession),
    TimedOut(ReviewSession),
}

const WAIT_POLL_INTERVAL_MS: u64 = 250;
const FOLLOW_AGENT_HEARTBEAT_INTERVAL_SECS: u64 = 30;
static ARGON_CLI_COMMAND: OnceLock<String> = OnceLock::new();

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    if sandbox::maybe_run_intercept_shim()? {
        return Ok(());
    }

    let raw_args: Vec<String> = std::env::args().collect();
    if let Some((path, launch)) = maybe_direct_path_invocation(&raw_args) {
        return run_path_workspace(path, &launch);
    }

    let cli = Cli::parse();
    let runtime = RuntimeOptions {
        launch: LaunchOptions {
            desktop_launch: normalize_override_path(cli.desktop_launch.clone()),
            agent_command: cli.agent.clone(),
            sandbox_agent: cli.sandbox,
            change_summary: cli.description.clone(),
        },
        repo_root_override: normalize_override_path(cli.repo.clone()),
    };

    let supports_agent_launch = matches!(
        &cli.command,
        Commands::Review(_) | Commands::Agent(AgentCommands::Start(_))
    );
    if runtime.launch.agent_command.is_some() && !supports_agent_launch {
        bail!(
            "--agent is only supported with session-starting commands (`argon <path>`, `argon review`, `argon agent start`)"
        );
    }
    if runtime.launch.sandbox_agent && runtime.launch.agent_command.is_none() {
        bail!("--sandbox requires --agent");
    }
    if runtime.launch.sandbox_agent && !supports_agent_launch {
        bail!(
            "--sandbox is only supported with session-starting commands (`argon <path>`, `argon review`, `argon agent start`)"
        );
    }
    if runtime.launch.change_summary.is_some() && !supports_agent_launch {
        bail!(
            "--description is only supported with session-starting commands (`argon <path>`, `argon review`, `argon agent start`)"
        );
    }

    match cli.command {
        Commands::Review(args) => run_review(args, &runtime),
        Commands::Agent(command) => run_agent(command, &runtime),
        Commands::Sandbox(command) => run_sandbox(command, &runtime),
        Commands::Reviewer(command) => run_reviewer(command, &runtime),
        Commands::Diff(args) => run_diff(args, &runtime),
        Commands::Highlight(args) => run_highlight(args),
        Commands::Draft(command) => run_draft(command, &runtime),
        Commands::Skill(command) => run_skill(command),
    }
}

fn maybe_direct_path_invocation(raw_args: &[String]) -> Option<(PathBuf, LaunchOptions)> {
    if raw_args.len() < 2 {
        return None;
    }

    let mut positional = Vec::<String>::new();
    let mut desktop_launch = None;
    let mut agent_command = None;
    let mut sandbox_agent = false;
    let mut change_summary = None;
    let mut repo_flag = None;
    let mut index = 1;
    while index < raw_args.len() {
        let token = &raw_args[index];
        if token == "--desktop-launch" {
            let value = raw_args.get(index + 1)?;
            desktop_launch = Some(PathBuf::from(value));
            index += 2;
            continue;
        }
        if token == "--repo" {
            let value = raw_args.get(index + 1)?;
            repo_flag = Some(PathBuf::from(value));
            index += 2;
            continue;
        }
        if token == "--agent" {
            let value = raw_args.get(index + 1)?;
            agent_command = Some(value.clone());
            index += 2;
            continue;
        }
        if token == "--sandbox" {
            sandbox_agent = true;
            index += 1;
            continue;
        }
        if token == "--description" {
            let value = raw_args.get(index + 1)?;
            change_summary = Some(value.clone());
            index += 2;
            continue;
        }

        if token.starts_with('-') {
            return None;
        }
        positional.push(token.clone());
        index += 1;
    }

    if positional.len() != 1 {
        return None;
    }

    let token = &positional[0];
    if is_command_token(token) {
        return None;
    }

    if repo_flag.is_some() {
        return None;
    }

    Some((
        PathBuf::from(token),
        LaunchOptions {
            desktop_launch: normalize_override_path(desktop_launch),
            agent_command,
            sandbox_agent,
            change_summary,
        },
    ))
}

fn is_command_token(token: &str) -> bool {
    matches!(
        token,
        "review" | "agent" | "sandbox" | "reviewer" | "diff" | "draft" | "skill" | "help"
    )
}

fn run_path_workspace(path: PathBuf, launch: &LaunchOptions) -> Result<()> {
    if launch.agent_command.is_some() {
        bail!("--agent is only supported with session-starting review commands");
    }
    if launch.sandbox_agent {
        bail!("--sandbox is only supported with session-starting review commands");
    }
    if launch.change_summary.is_some() {
        bail!("--description is only supported with session-starting review commands");
    }

    let target = resolve_workspace_launch_target(&path)?;
    launch_desktop_app_for_workspace(&target, launch);

    println!("workspace: {}", target.repo_root.display());
    println!("common-dir: {}", target.repo_common_dir.display());
    println!(
        "selected-worktree: {}",
        target.selected_worktree_root.display()
    );
    Ok(())
}

fn run_agent(command: AgentCommands, runtime: &RuntimeOptions) -> Result<()> {
    match command {
        AgentCommands::Start(args) => run_start(args, runtime),
        AgentCommands::Wait(args) => run_wait(args, runtime),
        AgentCommands::Follow(args) => run_follow(args, runtime),
        AgentCommands::Status(args) => run_status(args, runtime),
        AgentCommands::Close(args) => run_close(args, runtime),
        AgentCommands::Reply(args) => run_reply(args, runtime),
        AgentCommands::Ack(args) => run_ack(args, runtime),
        AgentCommands::Prompt(args) => run_prompt(args, runtime),
        AgentCommands::Dev(command) => run_dev(command, runtime),
    }
}

fn run_sandbox(command: SandboxCommands, runtime: &RuntimeOptions) -> Result<()> {
    match command {
        SandboxCommands::Config(command) => run_sandbox_config(command, runtime),
        SandboxCommands::Init(args) => run_sandbox_init(args),
        SandboxCommands::Builtin(command) => run_sandbox_builtin(command),
        SandboxCommands::Check(args) => run_sandbox_check(args),
        SandboxCommands::Explain(args) => run_sandbox_explain(args),
        SandboxCommands::Seatbelt(args) => run_sandbox_seatbelt(args),
        SandboxCommands::ProxyHelper(args) => sandbox_proxy::run_proxy_helper(&args.config),
        SandboxCommands::Exec(args) => run_sandbox_exec(args),
    }
}

fn run_reviewer(command: ReviewerCommands, runtime: &RuntimeOptions) -> Result<()> {
    match command {
        ReviewerCommands::Prompt(args) => run_reviewer_prompt(args, runtime),
        ReviewerCommands::Wait(args) => run_reviewer_wait(args, runtime),
        ReviewerCommands::Comment(args) => run_reviewer_comment(args, runtime),
        ReviewerCommands::Decide(args) => run_reviewer_decide(args, runtime),
    }
}

fn run_diff(args: DiffArgs, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    let session = store.load(args.session)?;

    let diff = argon_core::build_review_diff(
        Path::new(&session.repo_root),
        session.mode,
        &session.base_ref,
        &session.head_ref,
        &session.merge_base_sha,
    )?;

    let highlighted = argon_core::highlight_diff(&diff, &args.theme);

    if args.json {
        println!("{}", serde_json::to_string_pretty(&highlighted)?);
    } else {
        for file in &highlighted.files {
            println!(
                "--- {} (+{} -{})",
                file.new_path, file.added_count, file.removed_count
            );
            for hunk in &file.unified_hunks {
                println!("{}", hunk.header);
                for line in &hunk.lines {
                    let marker = match line.kind {
                        argon_core::DiffLineKind::Context => " ",
                        argon_core::DiffLineKind::Added => "+",
                        argon_core::DiffLineKind::Removed => "-",
                    };
                    let text: String = line.spans.iter().map(|s| s.text.as_str()).collect();
                    println!("{marker}{text}");
                }
            }
        }
    }
    Ok(())
}

fn run_highlight(args: HighlightArgs) -> Result<()> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .context("failed to read highlight input from stdin")?;

    let lines = argon_core::highlight_text(&input, &args.path, &args.theme);
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&HighlightResponse { lines })?
        );
    } else {
        for line in lines {
            let text = line.into_iter().map(|span| span.text).collect::<String>();
            println!("{text}");
        }
    }
    Ok(())
}

fn run_draft(command: DraftCommands, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    match command {
        DraftCommands::Add(args) => {
            let anchor = argon_core::CommentAnchor {
                file_path: args.file,
                line_new: args.line_new,
                line_old: args.line_old,
            };
            let draft = store.upsert_draft_comment(
                args.session,
                None,
                args.thread,
                args.message,
                anchor,
            )?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&draft)?);
            } else {
                println!("draft-comments: {}", draft.comments.len());
                if let Some(last) = draft.comments.last() {
                    println!("draft-id: {}", last.id);
                }
            }
            Ok(())
        }
        DraftCommands::Delete(args) => {
            let draft = store.delete_draft_comment(args.session, args.draft_id)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&draft)?);
            } else {
                println!("draft-comments: {}", draft.comments.len());
            }
            Ok(())
        }
        DraftCommands::List(args) => {
            let draft = store.load_draft_review(args.session)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&draft)?);
            } else {
                println!("session: {}", draft.session_id);
                println!("draft-comments: {}", draft.comments.len());
                for comment in &draft.comments {
                    let anchor = match (&comment.anchor.file_path, comment.anchor.line_new) {
                        (Some(path), Some(line)) => format!("{path}:{line}"),
                        (Some(path), None) => path.clone(),
                        _ => "global".to_string(),
                    };
                    println!("  {} [{}] {}", comment.id, anchor, comment.body);
                }
            }
            Ok(())
        }
        DraftCommands::Submit(args) => {
            let (session, count) = store.submit_draft_review(args.session)?;
            if let Some(outcome) = args.outcome {
                let session = store.set_decision(args.session, outcome.into(), args.summary)?;
                if args.json {
                    let payload = CliResponse::new(CliCommand::ReviewerDecide, &session);
                    println!("{}", serde_json::to_string_pretty(&payload)?);
                } else {
                    println!("submitted: {count} comments");
                    println!(
                        "decision: {:?}",
                        session.decision.as_ref().map(|d| &d.outcome)
                    );
                    println!("status: {:?}", session.status);
                }
            } else if args.json {
                let payload = CliResponse::new(CliCommand::ReviewerComment, &session);
                println!("{}", serde_json::to_string_pretty(&payload)?);
            } else {
                println!("submitted: {count} comments");
                println!("status: {:?}", session.status);
            }
            Ok(())
        }
    }
}

fn run_skill(command: SkillCommands) -> Result<()> {
    match command {
        SkillCommands::Install(args) => run_skill_install(args),
    }
}

fn run_skill_install(args: SkillInstallArgs) -> Result<()> {
    let skill_source = find_skill_source()?;
    let home_dir = dirs_home()?;

    let mut targets: Vec<(&str, PathBuf)> = Vec::new();
    match args.agent {
        SkillAgentArg::ClaudeCode => {
            targets.push(("claude-code", home_dir.join(".claude/skills")));
        }
        SkillAgentArg::Codex => {
            targets.push(("codex", home_dir.join(".codex/skills")));
        }
        SkillAgentArg::All => {
            targets.push(("claude-code", home_dir.join(".claude/skills")));
            targets.push(("codex", home_dir.join(".codex/skills")));
        }
    }

    for (agent_name, skills_home) in &targets {
        let dest = skills_home.join("argon-app-review");
        std::fs::create_dir_all(&dest)
            .with_context(|| format!("failed to create skill directory: {}", dest.display()))?;
        copy_dir_recursive(&skill_source, &dest)
            .with_context(|| format!("failed to copy skill to {}", dest.display()))?;
        println!(
            "installed argon-app-review skill for {agent_name} at {}",
            dest.display()
        );
    }

    Ok(())
}

fn find_skill_source() -> Result<PathBuf> {
    // Check relative to current executable for .app bundle layout
    if let Ok(exe) = std::env::current_exe() {
        let bundle_path = exe
            .parent()
            .and_then(|p| p.parent())
            .map(|p| p.join("Resources/skills/argon-app-review"));
        if let Some(path) = bundle_path
            && path.is_dir()
        {
            return Ok(path);
        }
    }

    // Check ARGON_SKILL_DIR env var
    if let Ok(dir) = std::env::var("ARGON_SKILL_DIR") {
        let path = PathBuf::from(&dir);
        if path.is_dir() {
            return Ok(path);
        }
    }

    // Check relative to CARGO_MANIFEST_DIR (development builds)
    if let Some(manifest_dir) = option_env!("CARGO_MANIFEST_DIR") {
        let workspace_root = PathBuf::from(manifest_dir)
            .ancestors()
            .nth(2)
            .map(|p| p.to_path_buf());
        if let Some(root) = workspace_root {
            let path = root.join("skills/argon-app-review");
            if path.is_dir() {
                return Ok(path);
            }
        }
    }

    bail!(
        "could not find bundled skill directory; set ARGON_SKILL_DIR or run from an Argon.app bundle"
    )
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    for entry in std::fs::read_dir(src).with_context(|| format!("reading {}", src.display()))? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        if file_type.is_dir() {
            std::fs::create_dir_all(&dst_path)?;
            copy_dir_recursive(&src_path, &dst_path)?;
        } else {
            std::fs::copy(&src_path, &dst_path)?;
        }
    }
    Ok(())
}

fn dirs_home() -> Result<PathBuf> {
    std::env::var("HOME")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("USERPROFILE").map(PathBuf::from))
        .context("could not determine home directory (HOME or USERPROFILE not set)")
}

fn run_start(args: StartArgs, runtime: &RuntimeOptions) -> Result<()> {
    if args.json && runtime.launch.agent_command.is_some() {
        bail!("--agent cannot be combined with --json");
    }

    let repo_root = resolved_repo_root(runtime)?;

    let target = match args.mode.map(ReviewMode::from) {
        Some(ReviewMode::Branch) => {
            let base = args.base.as_deref();
            let head = args.head.as_deref();
            if base.is_none() || head.is_none() {
                bail!("--mode branch requires both --base and --head");
            }
            resolve_branch_target(&repo_root, base, head)?
        }
        Some(ReviewMode::Commit) => resolve_commit_target(&repo_root, None)?,
        Some(ReviewMode::Uncommitted) => resolve_uncommitted_target(&repo_root)?,
        None => {
            if args.base.is_some() || args.head.is_some() {
                bail!("--base and --head require --mode branch");
            }
            auto_detect_review_target(&repo_root)?
        }
    };

    let store = SessionStore::for_repo_root(repo_root.clone());
    let created = store.create_session_with_details(
        target.mode,
        target.base_ref,
        target.head_ref,
        target.merge_base_sha,
        runtime.launch.change_summary.clone(),
    )?;
    let session = store.mark_agent_seen(created.id)?;
    launch_desktop_app_for_session(&repo_root, session.id, &runtime.launch);
    maybe_launch_agent_for_session(
        &session,
        runtime.launch.agent_command.as_deref(),
        runtime.launch.sandbox_agent,
    )?;

    if args.wait {
        let wait_result = wait_for_decision(&store, session.id, args.timeout_secs)?;
        print_wait_result(CliCommand::Start, wait_result, args.json, args.timeout_secs)
    } else {
        print_session(CliCommand::Start, &session, args.json)
    }
}

fn run_review(args: ReviewArgs, runtime: &RuntimeOptions) -> Result<()> {
    if args.json && runtime.launch.agent_command.is_some() {
        bail!("--agent cannot be combined with --json");
    }

    let repo_root = resolved_review_repo_root(&args, runtime)?;
    let target = resolve_review_target_for_review(&repo_root, &args)?;

    let store = SessionStore::for_repo_root(repo_root.clone());
    let session = store.create_session_with_details(
        target.mode,
        target.base_ref,
        target.head_ref,
        target.merge_base_sha,
        runtime.launch.change_summary.clone(),
    )?;
    launch_desktop_app_for_session(&repo_root, session.id, &runtime.launch);
    maybe_launch_agent_for_session(
        &session,
        runtime.launch.agent_command.as_deref(),
        runtime.launch.sandbox_agent,
    )?;

    if args.wait {
        let wait_result = wait_for_decision(&store, session.id, args.timeout_secs)?;
        print_wait_result(
            CliCommand::Review,
            wait_result,
            args.json,
            args.timeout_secs,
        )
    } else {
        print_session(CliCommand::Review, &session, args.json)
    }
}

fn resolve_review_target_for_review(
    repo_root: &Path,
    args: &ReviewArgs,
) -> Result<ResolvedReviewTarget> {
    if args.pr {
        if args.mode.is_some() || args.commit.is_some() {
            bail!("--pr cannot be combined with --mode or --commit");
        }
        let refs = pr_refs()?;
        return Ok(resolve_branch_target(
            repo_root,
            Some(&refs.base_ref),
            Some(&refs.head_ref),
        )?);
    }

    match args.mode.map(ReviewMode::from) {
        Some(ReviewMode::Branch) => {
            if args.commit.is_some() {
                bail!("--mode branch cannot be combined with --commit");
            }
            Ok(resolve_branch_target(
                repo_root,
                args.base.as_deref(),
                args.head.as_deref(),
            )?)
        }
        Some(ReviewMode::Commit) => {
            if args.base.is_some() || args.head.is_some() {
                bail!("--mode commit cannot be combined with --base/--head");
            }
            Ok(resolve_commit_target(repo_root, args.commit.as_deref())?)
        }
        Some(ReviewMode::Uncommitted) => {
            if args.base.is_some() || args.head.is_some() || args.commit.is_some() {
                bail!("--mode uncommitted cannot be combined with --base/--head/--commit");
            }
            Ok(resolve_uncommitted_target(repo_root)?)
        }
        None => {
            if args.commit.is_some() {
                if args.base.is_some() || args.head.is_some() {
                    bail!("--commit cannot be combined with --base/--head");
                }
                return Ok(resolve_commit_target(repo_root, args.commit.as_deref())?);
            }

            if args.base.is_some() || args.head.is_some() {
                return Ok(resolve_branch_target(
                    repo_root,
                    args.base.as_deref(),
                    args.head.as_deref(),
                )?);
            }

            Ok(auto_detect_review_target(repo_root)?)
        }
    }
}

fn run_wait(args: WaitArgs, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    let wait_result = wait_for_decision(&store, args.session, args.timeout_secs)?;
    print_wait_result(CliCommand::Wait, wait_result, args.json, args.timeout_secs)
}

fn run_follow(args: FollowArgs, runtime: &RuntimeOptions) -> Result<()> {
    if !args.jsonl {
        bail!("agent follow currently requires --jsonl");
    }

    let store = open_store_for_current_repo(runtime)?;
    let _ = store.mark_agent_seen(args.session)?;
    follow_session_events(&store, args.session)
}

fn run_status(args: StatusArgs, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    let session = store.mark_agent_seen(args.session)?;
    print_session(CliCommand::Status, &session, args.json)
}

fn run_close(args: CloseArgs, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    let session = store.close_session(args.session)?;
    print_session(CliCommand::Close, &session, args.json)
}

fn run_reply(args: ReplyArgs, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    let session = store.add_agent_reply(args.session, args.thread, args.message, args.addressed)?;
    print_session(CliCommand::Reply, &session, args.json)
}

fn run_ack(args: AckArgs, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    let session = store.acknowledge_thread(args.session, args.thread)?;
    print_session(CliCommand::Ack, &session, args.json)
}

fn run_prompt(args: PromptArgs, runtime: &RuntimeOptions) -> Result<()> {
    if args.json && args.launch.is_some() {
        bail!("--json cannot be combined with --launch");
    }
    if args.sandbox && args.launch.is_none() {
        bail!("--sandbox requires --launch");
    }

    let store = open_store_for_current_repo(runtime)?;
    let session = store.load(args.session)?;
    let pending_feedback = collect_pending_feedback(&session);
    let continue_command = agent_wait_command(&session);
    let prompt = build_agent_prompt(&session, &pending_feedback, &continue_command);

    if args.json {
        let payload = AgentPromptResponse {
            schema_version: argon_core::SCHEMA_VERSION.to_string(),
            command: CliCommand::Prompt,
            session: SessionPayload::from(&session),
            pending_feedback,
            continue_command,
            prompt,
        };
        println!("{}", serde_json::to_string_pretty(&payload)?);
        return Ok(());
    }

    println!("session: {}", session.id);
    println!("status: {:?}", session.status);
    println!("pending-feedback: {}", pending_feedback.len());
    println!("agent-prompt-command: {}", agent_prompt_command(&session));
    println!("continue-command: {continue_command}");
    println!();
    println!("{prompt}");

    if let Some(template) = args.launch.as_deref() {
        launch_agent_command(&session, &prompt, &continue_command, template, args.sandbox)?;
    }
    Ok(())
}

fn run_reviewer_prompt(args: ReviewerPromptArgs, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    let session = store.load(args.session)?;
    let reviewer_name = normalize_reviewer_name(args.reviewer.as_deref());
    let last_seen_at = store.load_reviewer_last_seen(args.session, &reviewer_name)?;
    let pending_feedback =
        collect_pending_reviewer_feedback(&session, &reviewer_name, last_seen_at);
    let continue_command = reviewer_wait_command(&session, &reviewer_name);
    let comment_command_template = reviewer_comment_command_template(&session, &reviewer_name);
    let decision_command_template = reviewer_decide_command_template(&session, &reviewer_name);
    let prompt = build_reviewer_prompt(
        &session,
        &reviewer_name,
        &pending_feedback,
        &continue_command,
        &comment_command_template,
        &decision_command_template,
    );
    mark_reviewer_feedback_seen(&store, args.session, &reviewer_name, &pending_feedback)?;

    if args.json {
        let payload = ReviewerPromptResponse {
            schema_version: argon_core::SCHEMA_VERSION.to_string(),
            command: CliCommand::ReviewerPrompt,
            session: SessionPayload::from(&session),
            reviewer_name,
            pending_feedback,
            continue_command,
            comment_command_template,
            decision_command_template,
            prompt,
        };
        println!("{}", serde_json::to_string_pretty(&payload)?);
        return Ok(());
    }

    println!("session: {}", session.id);
    println!("status: {:?}", session.status);
    println!("reviewer: {reviewer_name}");
    println!("pending-feedback: {}", pending_feedback.len());
    println!("reviewer-comment-command: {comment_command_template}");
    println!("reviewer-wait-command: {continue_command}");
    println!("reviewer-decision-command: {decision_command_template}");
    println!();
    println!("{prompt}");
    Ok(())
}

fn run_reviewer_wait(args: ReviewerWaitArgs, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    let reviewer_name = normalize_reviewer_name(args.reviewer.as_deref());
    let wait_result =
        wait_for_reviewer_feedback(&store, args.session, &reviewer_name, args.timeout_secs)?;
    print_wait_result(
        CliCommand::ReviewerWait,
        wait_result,
        args.json,
        args.timeout_secs,
    )
}

fn run_reviewer_comment(args: ReviewerCommentArgs, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    let reviewer_name = normalize_reviewer_name(args.reviewer.as_deref());
    let kind = if args.file.is_some() || args.line_new.is_some() || args.line_old.is_some() {
        CommentKind::Line
    } else {
        CommentKind::Global
    };
    let anchor = CommentAnchor {
        file_path: args.file,
        line_new: args.line_new,
        line_old: args.line_old,
    };
    let (session, _thread_id) = store.add_reviewer_comment(
        args.session,
        args.message,
        Some(reviewer_name),
        kind,
        anchor,
        args.thread,
    )?;
    print_session(CliCommand::ReviewerComment, &session, args.json)
}

fn run_reviewer_decide(args: ReviewerDecideArgs, runtime: &RuntimeOptions) -> Result<()> {
    if args.reviewer.is_some() && matches!(args.outcome, OutcomeArg::Approved) {
        bail!(
            "named reviewer agents cannot approve a session; use `commented` or `changes-requested`, and let the human reviewer decide whether to approve or close the session"
        );
    }

    let store = open_store_for_current_repo(runtime)?;
    let session = store.set_decision(args.session, args.outcome.into(), args.summary)?;
    print_session(CliCommand::ReviewerDecide, &session, args.json)
}

fn build_reviewer_prompt(
    session: &ReviewSession,
    reviewer_name: &str,
    pending_feedback: &[ReviewerFeedback],
    continue_command: &str,
    comment_command_template: &str,
    decision_command_template: &str,
) -> String {
    let mut lines = Vec::new();
    lines.push(format!(
        "You are reviewer {} for Argon session {} in {}.",
        shell_quote(reviewer_name),
        session.id,
        session.repo_root
    ));
    lines.push(format!(
        "Review target: mode={} base={} head={}",
        match session.mode {
            ReviewMode::Branch => "branch",
            ReviewMode::Commit => "commit",
            ReviewMode::Uncommitted => "uncommitted",
        },
        session.base_ref,
        session.head_ref
    ));
    if let Some(change_summary) = session.change_summary.as_deref() {
        lines.push(format!(
            "Planned changes from the coding agent: {change_summary}"
        ));
    }
    lines.push("Review the current local changes and leave feedback in Argon.".to_string());
    lines.push("Do not edit files or apply code changes yourself.".to_string());
    lines.push(
        "Do NOT use the argon-app-review or argon-dev-review skills. You are already inside an Argon review session. Use only the reviewer comment, decide, and wait commands listed in this prompt."
            .to_string(),
    );
    lines.push(
        "You may inspect the repo and run tests or other read-only commands to validate the work."
            .to_string(),
    );
    lines.push("Inspect the review target with git before commenting:".to_string());
    for command in reviewer_inspection_commands(session) {
        lines.push(format!("  {command}"));
    }
    lines.push("Use reviewer comment commands to record actionable findings.".to_string());
    lines.push(format!(
        "Comment template: {comment_command_template} --message \"<comment>\""
    ));
    lines.push(
        "Add --file <path> and optionally --line-old/--line-new when you can anchor the comment to a changed line."
            .to_string(),
    );
    lines.push(format!(
        "Resolve a thread when addressed: {} --repo {} agent dev resolve-thread --session {} --thread <thread-id>",
        argon_cli_command(),
        shell_quote(&session.repo_root),
        session.id
    ));
    lines.push(
        "Do NOT post 'Reviewing...' or progress-update comments as thread comments — they create noisy open threads. Only post substantive findings as comments."
            .to_string(),
    );
    lines.push(
        "When you finish a review round, submit a decision. Your comments are only batched and delivered to the coding agent when you submit a decision — so always submit one. Leave all your comments first, then submit the decision."
            .to_string(),
    );
    lines.push(format!("Decision template: {decision_command_template}"));
    lines.push(
        "Review the change normally and submit your actual judgment. Use `changes-requested` when the coding agent must make changes. Use `commented` when the pass is clean or when feedback is non-blocking. You MUST always submit a decision — never end your review without one. The human sees your verdict to inform their final decision."
            .to_string(),
    );
    lines.push(
        "Reviewer agents do not submit `approved`. Submit `commented` or `changes-requested`, and let the human reviewer decide whether to approve or close the session."
            .to_string(),
    );
    lines.push(format!(
        "When there is nothing to do right now, wait with: {continue_command}"
    ));
    lines.push(
        "After you comment on a thread, you are subscribed to it. `reviewer wait` will wake you for later replies from the coding agent or any other reviewer on those threads."
            .to_string(),
    );
    lines.push(
        "Answer on the same thread with `--thread <thread-id>` whenever you are replying to an existing discussion."
            .to_string(),
    );
    lines.push(
        "When a concern is addressed or no longer relevant, resolve the thread. The human can see which threads are still open."
            .to_string(),
    );
    lines.push(
        "Use conventional comment prefixes: 'nit:' for minor style issues, 'suggestion:' for optional improvements, 'issue:' for things that must change, 'question:' for things you want clarified. Do NOT post praise comments as thread comments — include positive observations in your decision summary instead. Only post comments that require attention or action."
            .to_string(),
    );
    lines.push(
        "IMPORTANT: After submitting your decision and comments, run the wait command to keep monitoring. You may receive replies from the coding agent addressing your feedback, from the human reviewer adding their own comments, or from other reviewer agents. Respond to all of them on the relevant threads. Keep looping: review → comment → decide → wait → respond to replies → wait again. Only stop when the session becomes `approved` or `closed`."
            .to_string(),
    );

    if pending_feedback.is_empty() {
        lines.push(
            "Current snapshot: no subscribed thread updates are waiting right now.".to_string(),
        );
    } else {
        lines.push(
            "Current snapshot: pending subscribed thread updates (review these now):".to_string(),
        );
        for (index, item) in pending_feedback.iter().enumerate() {
            let anchor = match (
                &item.anchor.file_path,
                item.anchor.line_old,
                item.anchor.line_new,
            ) {
                (Some(path), old, new) => format!("{path} (old:{old:?} new:{new:?})"),
                _ => "global".to_string(),
            };
            lines.push(format!(
                "{}. thread {} at {} -> {}{}",
                index + 1,
                item.thread_id,
                anchor,
                feedback_author_label(item),
                item.latest_comment
            ));
            lines.push(format!(
                "   respond with: {comment_command_template} --thread {} --message \"<response>\"",
                item.thread_id
            ));
        }
    }
    lines.join("\n")
}

fn reviewer_inspection_commands(session: &ReviewSession) -> Vec<String> {
    let repo_root = shell_quote(&session.repo_root);
    match session.mode {
        ReviewMode::Branch => vec![
            format!("git -C {repo_root} status --short"),
            format!(
                "git -C {repo_root} diff --no-color {} {}",
                shell_quote(&session.merge_base_sha),
                shell_quote(&session.head_ref)
            ),
        ],
        ReviewMode::Commit => vec![
            format!(
                "git -C {repo_root} show --stat --patch --no-color {}",
                shell_quote(&session.head_ref)
            ),
            format!(
                "git -C {repo_root} diff --no-color {} {}",
                shell_quote(&session.base_ref),
                shell_quote(&session.head_ref)
            ),
        ],
        ReviewMode::Uncommitted => vec![
            format!("git -C {repo_root} status --short"),
            format!("git -C {repo_root} diff --no-color HEAD"),
        ],
    }
}

fn collect_pending_feedback(session: &ReviewSession) -> Vec<PendingFeedback> {
    session
        .threads
        .iter()
        .filter_map(|thread| {
            if thread.state != ThreadState::Open {
                return None;
            }
            let latest = thread.comments.last()?;
            if latest.author != CommentAuthor::Reviewer {
                return None;
            }

            Some(PendingFeedback {
                thread_id: thread.id,
                anchor: latest.anchor.clone(),
                reviewer_comment: latest.body.clone(),
            })
        })
        .collect()
}

fn collect_pending_reviewer_feedback(
    session: &ReviewSession,
    reviewer_name: &str,
    last_seen_at: Option<DateTime<Utc>>,
) -> Vec<ReviewerFeedback> {
    session
        .threads
        .iter()
        .filter_map(|thread| {
            if thread.state == ThreadState::Resolved {
                return None;
            }

            let latest = thread.comments.last()?;
            let latest_reviewer_comment = thread
                .comments
                .iter()
                .rev()
                .find(|comment| reviewer_comment_matches(comment, reviewer_name))?;
            if latest.id == latest_reviewer_comment.id {
                return None;
            }
            let threshold = match last_seen_at {
                Some(last_seen_at) if last_seen_at > latest_reviewer_comment.created_at => {
                    last_seen_at
                }
                _ => latest_reviewer_comment.created_at,
            };
            if latest.created_at <= threshold {
                return None;
            }

            Some(ReviewerFeedback {
                thread_id: thread.id,
                anchor: latest.anchor.clone(),
                latest_author: latest.author,
                latest_author_name: latest.author_name.clone(),
                latest_comment: latest.body.clone(),
                created_at: latest.created_at,
            })
        })
        .collect()
}

fn reviewer_comment_matches(comment: &ReviewComment, reviewer_name: &str) -> bool {
    comment.author == CommentAuthor::Reviewer
        && comment.author_name.as_deref() == Some(reviewer_name)
}

fn feedback_author_label(feedback: &ReviewerFeedback) -> String {
    match feedback.latest_author {
        CommentAuthor::Agent => "agent -> ".to_string(),
        CommentAuthor::Reviewer => match feedback.latest_author_name.as_deref() {
            Some(name) => format!("{name} -> "),
            None => "reviewer -> ".to_string(),
        },
    }
}

fn latest_feedback_seen_at(pending_feedback: &[ReviewerFeedback]) -> Option<DateTime<Utc>> {
    pending_feedback
        .iter()
        .map(|feedback| feedback.created_at)
        .max()
}

fn mark_reviewer_feedback_seen(
    store: &SessionStore,
    session_id: Uuid,
    reviewer_name: &str,
    pending_feedback: &[ReviewerFeedback],
) -> Result<()> {
    let Some(last_seen_at) = latest_feedback_seen_at(pending_feedback) else {
        return Ok(());
    };
    store.mark_reviewer_seen(session_id, reviewer_name, Some(last_seen_at))?;
    Ok(())
}

fn normalize_reviewer_name(raw: Option<&str>) -> String {
    let trimmed = raw.unwrap_or("reviewer").trim();
    if trimmed.is_empty() {
        "reviewer".to_string()
    } else {
        trimmed.to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FollowStateSignature {
    status: SessionStatus,
    decision: Option<argon_core::ReviewDecision>,
    pending_feedback: Vec<(Uuid, Uuid)>,
}

fn pending_feedback_signature(session: &ReviewSession) -> Vec<(Uuid, Uuid)> {
    session
        .threads
        .iter()
        .filter_map(|thread| {
            if thread.state != ThreadState::Open {
                return None;
            }
            let latest = thread.comments.last()?;
            if latest.author != CommentAuthor::Reviewer {
                return None;
            }

            Some((thread.id, latest.id))
        })
        .collect()
}

fn agent_wait_signature(session: &ReviewSession) -> AgentWaitSignature {
    AgentWaitSignature {
        decision: session.decision.clone(),
        pending_feedback: pending_feedback_signature(session),
    }
}

fn current_follow_signature(session: &ReviewSession) -> FollowStateSignature {
    FollowStateSignature {
        status: session.status,
        decision: session.decision.clone(),
        pending_feedback: pending_feedback_signature(session),
    }
}

fn follow_event_kind(
    session: &ReviewSession,
    pending_feedback: &[PendingFeedback],
) -> AgentEventKind {
    if matches!(session.status, SessionStatus::Closed) {
        return AgentEventKind::ReviewerDecision;
    }
    if session.decision.is_some() {
        return AgentEventKind::ReviewerDecision;
    }
    if !pending_feedback.is_empty() {
        return AgentEventKind::ReviewerFeedback;
    }
    AgentEventKind::Snapshot
}

fn maybe_launch_agent_for_session(
    session: &ReviewSession,
    template: Option<&str>,
    sandbox_agent: bool,
) -> Result<()> {
    let Some(template) = template else {
        return Ok(());
    };

    let pending_feedback = collect_pending_feedback(session);
    let continue_command = agent_wait_command(session);
    let prompt = build_agent_prompt(session, &pending_feedback, &continue_command);
    launch_agent_command(session, &prompt, &continue_command, template, sandbox_agent)
}

fn build_agent_prompt(
    session: &ReviewSession,
    pending_feedback: &[PendingFeedback],
    continue_command: &str,
) -> String {
    let mut lines = Vec::new();
    lines.push(format!(
        "You are reviewing feedback for Argon session {} in {}.",
        session.id, session.repo_root
    ));
    lines.push(format!(
        "Review target: mode={} base={} head={}",
        match session.mode {
            ReviewMode::Branch => "branch",
            ReviewMode::Commit => "commit",
            ReviewMode::Uncommitted => "uncommitted",
        },
        session.base_ref,
        session.head_ref
    ));
    if let Some(change_summary) = session.change_summary.as_deref() {
        lines.push(format!("Planned changes for this review: {change_summary}"));
    }
    lines.push("Execution contract:".to_string());
    lines.push(format!(
        "1) Use this blocking wait command to pause until reviewer activity or a final state: {continue_command}"
    ));
    lines.push(
        "2) If the current snapshot already has open reviewer threads, address them now. Otherwise run the wait command and react as soon as it returns reviewer feedback."
            .to_string(),
    );
    lines.push(format!(
        "   acknowledge command template: {} --repo {} agent ack --session {} --thread <thread-id>",
        argon_cli_command(),
        shell_quote(&session.repo_root),
        session.id
    ));
    lines.push(
        "3) After acknowledging, implement the changes and reply on every acknowledged thread."
            .to_string(),
    );
    lines.push(format!(
        "   reply command template: {} --repo {} agent reply --session {} --thread <thread-id> --message \"<what changed>\" --addressed",
        argon_cli_command(),
        shell_quote(&session.repo_root),
        session.id
    ));
    lines.push(
        "4) After replying, run the same wait command again and continue this loop without disconnecting."
            .to_string(),
    );
    lines.push(
        "5) If the wait command returns `approved`, commit your changes (unless the reviewer explicitly asked for a different finalization step) and then stop. If it returns `closed`, the human ended the Argon session. Those are the only terminal states."
            .to_string(),
    );
    lines.push(
        "6) Do not keep a background `agent follow --jsonl` process as the primary loop in Codex; its output does not drive the agent's control flow."
            .to_string(),
    );
    lines.push(
        "7) Do not stop just because another reviewer agent says the work looks good; keep going until the human approves or closes the session."
            .to_string(),
    );

    if let Some(decision) = session.decision.as_ref() {
        let outcome = match decision.outcome {
            ReviewOutcome::Approved => "approved",
            ReviewOutcome::ChangesRequested => "changes_requested",
            ReviewOutcome::Commented => "commented",
        };
        let summary = decision.summary.as_deref().unwrap_or("no summary");
        lines.push(format!(
            "Current reviewer decision snapshot: {outcome} — {summary}."
        ));
        lines.push(
            "Treat non-terminal reviewer decisions as part of the active review. Address them if needed, then stay in the wait loop until the session is approved or closed."
                .to_string(),
        );
    }

    if pending_feedback.is_empty() {
        lines.push("Current snapshot: no open reviewer threads right now.".to_string());
    } else {
        lines
            .push("Current snapshot: pending reviewer feedback (address immediately):".to_string());
        for (index, item) in pending_feedback.iter().enumerate() {
            let anchor = match (
                &item.anchor.file_path,
                item.anchor.line_old,
                item.anchor.line_new,
            ) {
                (Some(path), old, new) => format!("{path} (old:{old:?} new:{new:?})"),
                _ => "global".to_string(),
            };
            lines.push(format!(
                "{}. thread {} at {} -> {}",
                index + 1,
                item.thread_id,
                anchor,
                item.reviewer_comment
            ));
            lines.push(format!(
                "   acknowledge with: {} --repo {} agent ack --session {} --thread {}",
                argon_cli_command(),
                shell_quote(&session.repo_root),
                session.id,
                item.thread_id
            ));
            lines.push(format!(
                "   reply with: {} --repo {} agent reply --session {} --thread {} --message \"<what changed>\" --addressed",
                argon_cli_command(),
                shell_quote(&session.repo_root), session.id, item.thread_id
            ));
        }
        lines.push("Address these now while keeping the stream open.".to_string());
    }

    lines.join("\n")
}

fn launch_agent_command(
    session: &ReviewSession,
    prompt: &str,
    continue_command: &str,
    template: &str,
    sandbox_agent: bool,
) -> Result<()> {
    let command = render_agent_launch_command(template, session, prompt, continue_command);
    let mut process = if sandbox_agent {
        sandbox_exec_shell_command(session, &command)?
    } else {
        shell_command(&command)
    };
    let status = process
        .current_dir(&session.repo_root)
        .env("ARGON_SESSION_ID", session.id.to_string())
        .env("ARGON_REPO_ROOT", &session.repo_root)
        .env("ARGON_AGENT_PROMPT", prompt)
        .env("ARGON_AGENT_CONTINUE_COMMAND", continue_command)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .with_context(|| format!("failed to launch agent command: {command}"))?;

    if !status.success() {
        bail!("agent command exited with status: {status}");
    }

    Ok(())
}

fn render_agent_launch_command(
    template: &str,
    session: &ReviewSession,
    prompt: &str,
    continue_command: &str,
) -> String {
    let prompt_quoted = shell_quote(prompt);
    let session_id = session.id.to_string();
    let repo_root = shell_quote(&session.repo_root);
    let continue_quoted = shell_quote(continue_command);
    let has_prompt_placeholder = template.contains("{{prompt}}");

    let rendered = template
        .replace("{{prompt}}", &prompt_quoted)
        .replace("{{session_id}}", &session_id)
        .replace("{{repo_root}}", &repo_root)
        .replace("{{continue_command}}", &continue_quoted);

    if has_prompt_placeholder {
        rendered
    } else {
        format!("{rendered} {prompt_quoted}")
    }
}

fn run_sandbox_config(command: SandboxConfigCommands, runtime: &RuntimeOptions) -> Result<()> {
    match command {
        SandboxConfigCommands::Paths(args) => run_sandbox_config_paths(args, runtime),
    }
}

fn run_sandbox_builtin(command: SandboxBuiltinCommands) -> Result<()> {
    match command {
        SandboxBuiltinCommands::List(args) => run_sandbox_builtin_list(args),
        SandboxBuiltinCommands::Print(args) => run_sandbox_builtin_print(args),
    }
}

fn run_sandbox_config_paths(args: SandboxConfigPathsArgs, runtime: &RuntimeOptions) -> Result<()> {
    let start_dir = resolved_sandbox_repo_root(runtime)?
        .unwrap_or(std::env::current_dir().context("failed to read current directory")?);
    let paths = sandbox::resolved_config_paths(&start_dir)?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&paths)?);
    } else {
        println!("Start Dir: {}", start_dir.display());
        if let Some(path) = paths.init_path.as_ref() {
            println!("Init Path: {}", path.display());
        }
        println!("Parsed Sandboxfiles:");
        if paths.existing_paths.is_empty() {
            println!("- (none)");
        } else {
            for path in &paths.existing_paths {
                println!("- {}", path.display());
            }
        }
    }
    Ok(())
}

fn run_sandbox_init(args: SandboxInitArgs) -> Result<()> {
    let current_dir = std::env::current_dir().context("failed to determine current directory")?;
    let context = SandboxContext::from_process_environment(current_dir.clone());
    let context = SandboxContext {
        repo_root: Some(args.repo_root.unwrap_or(current_dir)),
        ..context
    };
    let result = sandbox::ensure_sandboxfile(&context)?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&result)?);
    } else if result.created {
        println!("created: {}", result.path.display());
    } else {
        println!("existing: {}", result.path.display());
    }
    Ok(())
}

fn run_sandbox_builtin_list(args: SandboxBuiltinListArgs) -> Result<()> {
    let builtins = sandbox::list_builtin_names();
    if args.json {
        println!("{}", serde_json::to_string_pretty(&builtins)?);
    } else {
        for builtin in builtins {
            println!("{builtin}");
        }
    }
    Ok(())
}

fn run_sandbox_builtin_print(args: SandboxBuiltinPrintArgs) -> Result<()> {
    let context = sandbox_context_from_args(&args.context, &[])?;
    let preview = sandbox::builtin_preview(&args.name, &context)?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&preview)?);
        return Ok(());
    }

    print_sandbox_messages(&preview.infos, &preview.warnings);
    if let Some(resolved_name) = preview.resolved_name.as_ref() {
        println!("# builtin/{resolved_name}");
    }
    if let Some(source) = preview.source.as_ref() {
        print!("{source}");
    }
    Ok(())
}

fn run_sandbox_check(args: SandboxCheckArgs) -> Result<()> {
    let context = sandbox_context_from_args(&args.context, &[])?;
    let check = sandbox::check(&context, &args.context.write_roots)?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&check)?);
        return Ok(());
    }

    println!("Sandbox: valid");
    print_config_search(&check.paths);
    print_explained_sources(&check.sources);
    println!("Info:");
    if check.infos.is_empty() {
        println!("- (none)");
    } else {
        for info in &check.infos {
            println!("- {info}");
        }
    }
    println!("Warnings:");
    if check.warnings.is_empty() {
        println!("- (none)");
    } else {
        for warning in &check.warnings {
            println!("- {warning}");
        }
    }
    Ok(())
}

fn run_sandbox_explain(args: SandboxExplainArgs) -> Result<()> {
    let context = sandbox_context_from_args(&args.context, &[])?;
    let explain = sandbox::explain(&context, &args.context.write_roots)?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&explain)?);
    } else {
        println!("Launch: {:?}", context.launch);
        println!("Interactive: {}", context.interactive);
        println!("Current Dir: {}", context.current_dir.display());
        if let Some(repo_root) = context.repo_root.as_ref() {
            println!("Repo Root: {}", repo_root.display());
        }
        if let Some(session_dir) = context.session_dir.as_ref() {
            println!("Session Dir: {}", session_dir.display());
        }
        if let Some(shell) = context.shell.as_ref() {
            match context.shell_path.as_ref() {
                Some(path) => println!("Shell: {} ({})", shell, path.display()),
                None => println!("Shell: {shell}"),
            }
        }
        if let Some(agent) = context.agent.as_ref() {
            println!("Agent: {agent}");
        }
        if !explain.infos.is_empty() {
            println!("Info:");
            for info in &explain.infos {
                println!("- {info}");
            }
        }
        if !explain.warnings.is_empty() {
            println!("Warnings:");
            for warning in &explain.warnings {
                println!("- {warning}");
            }
        }
        print_config_search(&explain.paths);
        print_explained_sources(&explain.sources);
        print_filesystem_policy(&explain.policy);
        print_exec_policy(&explain.policy, &explain.intercepts);
        print_network_policy(&explain.policy);
        print_environment_policy(
            explain.environment_default,
            &explain.allowed_environment_patterns,
            &explain.environment,
            &explain.removed_environment_keys,
        );
    }
    Ok(())
}

fn run_sandbox_seatbelt(args: SandboxSeatbeltArgs) -> Result<()> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = args;
        bail!("sandbox seatbelt is only available on macOS");
    }

    #[cfg(target_os = "macos")]
    {
        let context = sandbox_context_from_args(&args.context, &[])?;
        let plan = sandbox::build_execution_plan(&context, &args.context.write_roots)?;
        let response = SandboxSeatbeltDebugResponse {
            profile: sandbox::profile_source(&plan.policy),
            parameters: sandbox::profile_parameters(&plan.policy),
            infos: plan.infos,
            warnings: plan.warnings,
        };
        if args.json {
            println!("{}", serde_json::to_string_pretty(&response)?);
        } else {
            print_sandbox_messages(&response.infos, &response.warnings);
            println!("{}", response.profile);
            println!();
            if response.parameters.is_empty() {
                println!("# parameters: (none)");
            } else {
                println!("# parameters");
                for pair in response.parameters.chunks(2) {
                    match pair {
                        [name, value] => println!("{name}={value}"),
                        [name] => println!("{name}"),
                        _ => {}
                    }
                }
            }
        }
        Ok(())
    }
}

fn print_config_search(paths: &sandbox::ResolvedConfigPaths) {
    println!("Parsed Sandboxfiles:");
    if paths.existing_paths.is_empty() {
        println!("- (none)");
        return;
    }

    for path in &paths.existing_paths {
        println!("- {}", path.display());
    }
}

fn print_explained_sources(sources: &[sandbox::ExplainedSource]) {
    println!("Sources:");
    if sources.is_empty() {
        println!("- (none)");
        return;
    }

    for source in sources {
        match source.path.as_ref() {
            Some(path) => println!("- {}: {} ({})", source.kind, source.name, path.display()),
            None => println!("- {}: {}", source.kind, source.name),
        }
    }
}

fn print_filesystem_policy(policy: &sandbox::EffectiveSandboxPolicy) {
    println!("Filesystem:");
    println!("- default: {:?}", policy.fs_default);
    let entries = filesystem_entries(policy);
    if entries.is_empty() {
        println!("- paths: (none)");
        return;
    }

    println!("- paths:");
    for entry in entries {
        println!(
            "  - {} [{}]",
            format_filesystem_path(&entry.path, entry.is_directory),
            filesystem_access_label(entry.read, entry.write)
        );
    }
}

fn print_exec_policy(
    policy: &sandbox::EffectiveSandboxPolicy,
    intercepts: &[sandbox::ResolvedIntercept],
) {
    println!("Exec:");
    println!("- default: {:?}", policy.exec_default);
    print_path_list("Executable Files", &policy.executable_paths);
    print_path_list("Executable Directories", &policy.executable_roots);
    println!("Intercepts:");
    if intercepts.is_empty() {
        println!("- (none)");
        return;
    }

    for intercept in intercepts {
        println!("- {}", intercept.command_name);
        println!("  handler: {}", intercept.handler_path.display());
        if let Some(path) = intercept.real_command_path.as_ref() {
            println!("  resolved: {}", path.display());
        }
        if let Some(path) = intercept.shim_path.as_ref() {
            println!("  shim: {}", path.display());
        }
    }
}

fn print_network_policy(policy: &sandbox::EffectiveSandboxPolicy) {
    println!("Network:");
    println!("- default: {:?}", policy.net_default);
    if policy.proxied_hosts.is_empty() {
        println!("- proxy: (none)");
    } else {
        println!("- proxy:");
        for value in &policy.proxied_hosts {
            println!("  - {value}");
        }
    }

    if policy.connect_rules.is_empty() {
        println!("- connect: (none)");
    } else {
        println!("- connect:");
        for rule in &policy.connect_rules {
            println!(
                "  - {} {}",
                network_protocol_label(rule.protocol),
                rule.target
            );
        }
    }
}

fn network_protocol_label(protocol: sandbox::NetProtocol) -> &'static str {
    match protocol {
        sandbox::NetProtocol::Tcp => "tcp",
        sandbox::NetProtocol::Udp => "udp",
    }
}

fn print_environment_policy(
    environment_default: sandbox::EnvDefault,
    allowed_environment_patterns: &[String],
    environment: &BTreeMap<String, String>,
    removed_environment_keys: &[String],
) {
    println!("Environment:");
    println!("- default: {:?}", environment_default);
    if allowed_environment_patterns.is_empty() {
        println!("- allow: (none)");
    } else {
        println!("- allow:");
        for pattern in allowed_environment_patterns {
            println!("  - {pattern}");
        }
    }

    if environment.is_empty() {
        println!("- set: (none)");
    } else {
        println!("- set:");
        for (key, value) in environment {
            println!("  - {key}={value}");
        }
    }

    if removed_environment_keys.is_empty() {
        println!("- unset: (none)");
    } else {
        println!("- unset:");
        for key in removed_environment_keys {
            println!("  - {key}");
        }
    }
}

fn print_path_list(label: &str, paths: &[PathBuf]) {
    println!("- {}:", label);
    if paths.is_empty() {
        println!("  - (none)");
        return;
    }

    for path in paths {
        println!("  - {}", path.display());
    }
}

#[derive(Default)]
struct FilesystemEntry {
    is_directory: bool,
    read: bool,
    write: bool,
}

struct FilesystemDisplayEntry {
    path: PathBuf,
    is_directory: bool,
    read: bool,
    write: bool,
}

fn filesystem_entries(policy: &sandbox::EffectiveSandboxPolicy) -> Vec<FilesystemDisplayEntry> {
    let mut entries = BTreeMap::<PathBuf, FilesystemEntry>::new();

    for path in &policy.readable_paths {
        let entry = entries.entry(path.clone()).or_default();
        entry.read = true;
    }
    for path in &policy.readable_roots {
        let entry = entries.entry(path.clone()).or_default();
        entry.is_directory = true;
        entry.read = true;
    }
    for path in &policy.writable_paths {
        let entry = entries.entry(path.clone()).or_default();
        entry.write = true;
    }
    for path in &policy.writable_roots {
        let entry = entries.entry(path.clone()).or_default();
        entry.is_directory = true;
        entry.write = true;
    }

    entries
        .into_iter()
        .map(|(path, entry)| FilesystemDisplayEntry {
            path,
            is_directory: entry.is_directory,
            read: entry.read,
            write: entry.write,
        })
        .collect()
}

fn format_filesystem_path(path: &Path, is_directory: bool) -> String {
    let mut display = path.display().to_string();
    if is_directory && display != "/" {
        display.push('/');
    }
    display
}

fn filesystem_access_label(read: bool, write: bool) -> &'static str {
    match (read, write) {
        (true, true) => "read, write",
        (true, false) => "read",
        (false, true) => "write",
        (false, false) => "none",
    }
}

fn run_sandbox_exec(args: SandboxExecArgs) -> Result<()> {
    let (program, command_args) = args
        .command
        .split_first()
        .context("sandbox exec requires a command after `--`")?;
    let context = sandbox_context_from_args(&args.context, &args.command)?;
    let init = sandbox::ensure_sandboxfile(&context)?;
    if init.created {
        eprintln!("created Sandboxfile at {}", init.path.display());
    }

    let mut plan = sandbox::build_execution_plan(&context, &args.context.write_roots)?;
    let mut runtime_policy = plan.policy.clone();
    let network_log_path = sandbox_proxy::prepare_network_log_for_current_tab()?;
    let requires_proxy_injection = matches!(runtime_policy.net_default, sandbox::NetDefault::None)
        && !runtime_policy.proxied_hosts.is_empty();
    if requires_proxy_injection {
        let current_exe =
            std::env::current_exe().context("failed to resolve the current argon executable")?;
        let proxy = sandbox_proxy::spawn_proxy_helper(
            &current_exe,
            &runtime_policy.proxied_hosts,
            network_log_path,
        )?;
        for (key, value) in proxy.environment {
            plan.environment.insert(key, value);
        }
        runtime_policy
            .connect_rules
            .push(sandbox_proxy::runtime_connect_rule(proxy.port));
    }
    print_sandbox_messages(&plan.infos, &plan.warnings);
    sandbox::apply_current_process(&runtime_policy)?;
    exec_command(program, command_args, &plan)
}

fn sandbox_context_from_args(
    args: &SandboxExecutionContextArgs,
    command: &[String],
) -> Result<SandboxContext> {
    let current_dir = std::env::current_dir().context("failed to determine current directory")?;
    let env = std::env::vars().collect::<BTreeMap<_, _>>();
    let shell_path = env
        .get("SHELL")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    let shell = shell_path
        .as_ref()
        .and_then(|path| path.file_name().and_then(OsStr::to_str))
        .map(str::to_owned);
    let launch = args.launch.map(Into::into).unwrap_or_else(|| {
        if args.interactive {
            LaunchKind::Shell
        } else {
            LaunchKind::Command
        }
    });

    Ok(SandboxContext {
        repo_root: Some(
            args.repo_root
                .clone()
                .unwrap_or_else(|| current_dir.clone()),
        ),
        current_dir,
        launch,
        interactive: args.interactive || matches!(launch, LaunchKind::Shell),
        shell,
        shell_path,
        agent: args.agent_family.clone(),
        session_dir: args.session_dir.clone(),
        argv: command.to_vec(),
        env,
    })
}

fn print_sandbox_messages(infos: &[String], warnings: &[String]) {
    for info in infos {
        eprintln!("{}: {info}", sandbox_message_prefix("info", "\u{1b}[36m"));
    }
    for warning in warnings {
        eprintln!(
            "{}: {warning}",
            sandbox_message_prefix("warning", "\u{1b}[33m")
        );
    }
}

fn sandbox_message_prefix(label: &str, color_code: &str) -> String {
    if std::io::stderr().is_terminal() {
        format!("{color_code}{label}\u{1b}[0m")
    } else {
        label.to_string()
    }
}

fn exec_command(
    program: &str,
    args: &[String],
    plan: &sandbox::SandboxExecutionPlan,
) -> Result<()> {
    let mut command = Command::new(program);
    command.args(args);

    let base_environment = std::env::vars().collect::<BTreeMap<_, _>>();
    let environment = sandbox::resolved_environment(plan, &base_environment);
    command.env_clear();
    command.envs(environment);

    #[cfg(unix)]
    {
        let error = command.exec();
        Err(anyhow::Error::new(error).context(format!("failed to exec {}", shell_quote(program))))
    }

    #[cfg(not(unix))]
    {
        let status = command
            .status()
            .with_context(|| format!("failed to launch {}", shell_quote(program)))?;
        if !status.success() {
            bail!("sandboxed command exited with status: {status}");
        }
        Ok(())
    }
}

fn sandbox_exec_shell_command(session: &ReviewSession, command: &str) -> Result<Command> {
    let current_exe =
        std::env::current_exe().context("failed to resolve the current argon executable")?;
    let store = SessionStore::for_repo_root(&session.repo_root);
    let mut child = Command::new(current_exe);
    child
        .arg("sandbox")
        .arg("exec")
        .arg("--repo-root")
        .arg(&session.repo_root)
        .arg("--write-root")
        .arg(&session.repo_root)
        .arg("--write-root")
        .arg(store.sessions_dir())
        .arg("--");

    #[cfg(target_os = "windows")]
    {
        child.arg("cmd").arg("/C").arg(command);
    }

    #[cfg(not(target_os = "windows"))]
    {
        child.arg("sh").arg("-lc").arg(command);
    }

    Ok(child)
}

fn resolved_sandbox_repo_root(runtime: &RuntimeOptions) -> Result<Option<PathBuf>> {
    if let Some(path) = &runtime.repo_root_override {
        return Ok(Some(path.clone()));
    }
    let current_dir = std::env::current_dir().context("failed to read current directory")?;
    Ok(Some(current_dir))
}

fn shell_command(command: &str) -> Command {
    #[cfg(target_os = "windows")]
    {
        let mut child = Command::new("cmd");
        child.arg("/C").arg(command);
        child
    }

    #[cfg(not(target_os = "windows"))]
    {
        let mut child = Command::new("sh");
        child.arg("-lc").arg(command);
        child
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::fs;
    #[cfg(unix)]
    use std::time::Duration;
    #[cfg(unix)]
    use tempfile::tempdir;

    fn sample_session() -> ReviewSession {
        ReviewSession::new(
            "/tmp/repo".to_string(),
            "main".to_string(),
            "feature/x".to_string(),
            "abc123".to_string(),
        )
    }

    #[test]
    fn render_agent_launch_command_appends_prompt_when_missing_placeholder() {
        let session = sample_session();
        let command =
            render_agent_launch_command("my-agent-cli", &session, "Please fix this", "continue");
        assert!(command.starts_with("my-agent-cli "));
        assert!(command.contains("Please fix this"));
    }

    #[test]
    fn render_agent_launch_command_replaces_placeholders() {
        let session = sample_session();
        let command = render_agent_launch_command(
            "runner --repo {{repo_root}} --sid {{session_id}} --note {{prompt}}",
            &session,
            "Need changes",
            "continue",
        );
        assert!(command.contains("--repo /tmp/repo"));
        assert!(command.contains("--sid "));
        assert!(command.contains("Need changes"));
        assert!(!command.contains("{{prompt}}"));
    }

    #[test]
    fn reviewer_prompt_tells_agents_to_submit_their_actual_judgment() {
        let session = sample_session();
        let prompt = build_reviewer_prompt(
            &session,
            "Frost",
            &[],
            "argon reviewer wait --session sid --reviewer Frost --json",
            "argon reviewer comment --session sid --reviewer Frost",
            "argon reviewer decide --session sid --reviewer Frost --outcome <changes-requested|commented>",
        );

        assert!(prompt.contains("Review the change normally and submit your actual judgment."));
        assert!(prompt.contains("Reviewer agents do not submit `approved`."));
        assert!(
            prompt
                .contains("let the human reviewer decide whether to approve or close the session.")
        );
        assert!(prompt.contains("Inspect the review target with git before commenting:"));
        assert!(prompt.contains("git -C /tmp/repo status --short"));
        assert!(prompt.contains("git -C /tmp/repo diff --no-color abc123 feature/x"));
    }

    #[test]
    fn agent_prompt_tells_coder_to_commit_on_approval() {
        let session = sample_session();
        let prompt = build_agent_prompt(
            &session,
            &[],
            "argon --repo /tmp/repo agent wait --session sid --json",
        );

        assert!(prompt.contains("commit your changes"));
        assert!(prompt.contains("without disconnecting"));
    }

    #[cfg(unix)]
    #[test]
    fn wait_for_decision_ignores_stale_non_terminal_snapshot() {
        let temp = tempdir().expect("tempdir");
        let repo_root = temp.path().join("repo");
        fs::create_dir_all(&repo_root).expect("create repo");
        let store = SessionStore::for_repo_root_with_storage_root(
            &repo_root,
            temp.path().join(".argon-home"),
        );
        let session = store
            .create_session_with_mode(ReviewMode::Uncommitted, "HEAD", "WORKTREE", "abc123")
            .expect("session");
        let (session, thread_id) = store
            .add_reviewer_comment(
                session.id,
                "issue: please clean this up",
                Some("Frost".to_string()),
                CommentKind::Global,
                CommentAnchor::default(),
                None,
            )
            .expect("reviewer comment");
        let session = store
            .set_decision(
                session.id,
                ReviewOutcome::Commented,
                Some("noted".to_string()),
            )
            .expect("decision");
        let _session = store
            .mark_thread_resolved(session.id, thread_id)
            .expect("resolve thread");

        let wait_result =
            wait_for_decision(&store, session.id, Some(0)).expect("wait should return");

        match wait_result {
            WaitResult::TimedOut(session) => {
                assert_eq!(session.status, SessionStatus::AwaitingReviewer);
                assert!(session.decision.is_some());
            }
            WaitResult::Ready(session) => {
                panic!(
                    "stale non-terminal session should not wake agent wait immediately: {:?}",
                    session.status
                );
            }
        }
    }

    #[test]
    fn direct_path_invocation_accepts_agent_flag() {
        let raw_args = vec![
            "argon".to_string(),
            "--desktop-launch".to_string(),
            "/tmp/launcher".to_string(),
            "--agent".to_string(),
            "codex --yolo".to_string(),
            ".".to_string(),
        ];
        let (path, launch) =
            maybe_direct_path_invocation(&raw_args).expect("expected direct path invocation");
        assert_eq!(path, PathBuf::from("."));
        assert_eq!(launch.desktop_launch, Some(PathBuf::from("/tmp/launcher")));
        assert_eq!(launch.agent_command.as_deref(), Some("codex --yolo"));
    }

    #[test]
    fn direct_path_invocation_accepts_sandbox_flag() {
        let raw_args = vec![
            "argon".to_string(),
            "--agent".to_string(),
            "codex".to_string(),
            "--sandbox".to_string(),
            ".".to_string(),
        ];
        let (path, launch) =
            maybe_direct_path_invocation(&raw_args).expect("expected direct path invocation");
        assert_eq!(path, PathBuf::from("."));
        assert_eq!(launch.agent_command.as_deref(), Some("codex"));
        assert!(launch.sandbox_agent);
    }

    #[test]
    fn review_command_accepts_positional_directory() {
        let cli = Cli::try_parse_from(["argon", "review", "/tmp/repo"]).expect("parse review");
        match cli.command {
            Commands::Review(args) => {
                assert_eq!(args.path, Some(PathBuf::from("/tmp/repo")));
            }
            other => panic!("expected review command, got {other:?}"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn desktop_spawn_detaches_into_new_session() {
        let temp = tempdir().expect("tempdir");
        let sid_path = temp.path().join("child.sid");
        let script = format!(
            "ps -o sid= -p $$ > {}",
            shell_quote(&sid_path.to_string_lossy())
        );

        let mut command = Command::new("sh");
        command.arg("-c").arg(script);

        let envs = vec![("ARGON_SESSION_ID", "test-session".to_string())];
        spawn_desktop_command(command, temp.path(), &envs).expect("spawn desktop command");

        for _ in 0..20 {
            if sid_path.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }

        let child_sid = fs::read_to_string(&sid_path)
            .expect("child sid file")
            .trim()
            .to_string();
        assert!(!child_sid.is_empty(), "child sid should not be empty");

        let parent_sid = unsafe { libc::getsid(0) };
        assert_ne!(child_sid, parent_sid.to_string());
    }
}

fn run_dev(command: DevCommands, runtime: &RuntimeOptions) -> Result<()> {
    let store = open_store_for_current_repo(runtime)?;
    match command {
        DevCommands::Comment(args) => {
            let kind = if args.file.is_some() || args.line_new.is_some() || args.line_old.is_some()
            {
                CommentKind::Line
            } else {
                CommentKind::Global
            };
            let anchor = CommentAnchor {
                file_path: args.file,
                line_new: args.line_new,
                line_old: args.line_old,
            };
            let (session, thread_id) = store.add_reviewer_comment(
                args.session,
                args.message,
                None,
                kind,
                anchor,
                args.thread,
            )?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&session)?);
            } else {
                println!("session: {}", session.id);
                println!("status: {:?}", session.status);
                println!("thread: {thread_id}");
            }
            Ok(())
        }
        DevCommands::Decide(args) => {
            let session = store.set_decision(args.session, args.outcome.into(), args.summary)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&session)?);
            } else {
                println!("session: {}", session.id);
                println!("status: {:?}", session.status);
                if let Some(decision) = &session.decision {
                    println!("decision: {:?}", decision.outcome);
                }
            }
            Ok(())
        }
        DevCommands::UpdateTarget(args) => {
            let session = store.update_session_target(
                args.session,
                args.mode.into(),
                args.base_ref,
                args.head_ref,
                args.merge_base_sha,
            )?;
            print_session(CliCommand::Review, &session, args.json)
        }
        DevCommands::ResolveThread(args) => {
            let session = store.mark_thread_resolved(args.session, args.thread)?;
            print_session(CliCommand::ReviewerComment, &session, args.json)
        }
    }
}

fn wait_for_decision(
    store: &SessionStore,
    session_id: Uuid,
    timeout_secs: Option<u64>,
) -> Result<WaitResult> {
    let started = Instant::now();
    let initial_session = store.load(session_id)?;
    if matches!(
        initial_session.status,
        SessionStatus::Approved | SessionStatus::Closed
    ) {
        let session = store.mark_agent_seen(session_id)?;
        return Ok(WaitResult::Ready(session));
    }

    let initial_pending_feedback = collect_pending_feedback(&initial_session);
    if !initial_pending_feedback.is_empty() {
        let session = store.mark_agent_seen(session_id)?;
        return Ok(WaitResult::Ready(session));
    }

    let initial_signature = agent_wait_signature(&initial_session);

    loop {
        let session = store.load(session_id)?;
        if matches!(
            session.status,
            SessionStatus::Approved | SessionStatus::Closed
        ) {
            let session = store.mark_agent_seen(session_id)?;
            return Ok(WaitResult::Ready(session));
        }

        let current_signature = agent_wait_signature(&session);
        let current_pending_feedback = collect_pending_feedback(&session);
        if current_signature.decision != initial_signature.decision
            || (!current_pending_feedback.is_empty()
                && current_signature.pending_feedback != initial_signature.pending_feedback)
        {
            let session = store.mark_agent_seen(session_id)?;
            return Ok(WaitResult::Ready(session));
        }

        if let Some(timeout_secs) = timeout_secs {
            let timeout = Duration::from_secs(timeout_secs);
            if started.elapsed() >= timeout {
                let session = store.mark_agent_seen(session_id)?;
                return Ok(WaitResult::TimedOut(session));
            }
        }

        thread::sleep(Duration::from_millis(WAIT_POLL_INTERVAL_MS));
    }
}

fn wait_for_reviewer_feedback(
    store: &SessionStore,
    session_id: Uuid,
    reviewer_name: &str,
    timeout_secs: Option<u64>,
) -> Result<WaitResult> {
    let started = Instant::now();
    let initial_session = store.load(session_id)?;
    let initial_status = initial_session.status;
    let initial_decision = initial_session.decision.is_some();
    let initial_thread_count = initial_session.threads.len();
    let initial_comment_count: usize = initial_session
        .threads
        .iter()
        .map(|t| t.comments.len())
        .sum();

    loop {
        let session = store.load(session_id)?;

        // Terminal states
        if matches!(
            session.status,
            SessionStatus::Approved | SessionStatus::Closed
        ) {
            return Ok(WaitResult::Ready(session));
        }

        // Check for pending feedback on subscribed threads
        let last_seen_at = store.load_reviewer_last_seen(session_id, reviewer_name)?;
        let pending_feedback =
            collect_pending_reviewer_feedback(&session, reviewer_name, last_seen_at);
        if !pending_feedback.is_empty() {
            mark_reviewer_feedback_seen(store, session_id, reviewer_name, &pending_feedback)?;
            return Ok(WaitResult::Ready(session));
        }

        // Also wake when session state changes materially (new threads,
        // new comments on any thread, status change, new decision)
        let current_thread_count = session.threads.len();
        let current_comment_count: usize = session.threads.iter().map(|t| t.comments.len()).sum();
        if session.status != initial_status
            || session.decision.is_some() != initial_decision
            || current_thread_count != initial_thread_count
            || current_comment_count != initial_comment_count
        {
            return Ok(WaitResult::Ready(session));
        }

        if let Some(timeout_secs) = timeout_secs {
            let timeout = Duration::from_secs(timeout_secs);
            if started.elapsed() >= timeout {
                return Ok(WaitResult::TimedOut(session));
            }
        }

        thread::sleep(Duration::from_millis(WAIT_POLL_INTERVAL_MS));
    }
}

fn follow_session_events(store: &SessionStore, session_id: Uuid) -> Result<()> {
    let mut last_emitted_signature: Option<FollowStateSignature> = None;
    let mut emitted_snapshot = false;
    let mut last_agent_seen_refresh = Instant::now();

    loop {
        if last_agent_seen_refresh.elapsed()
            >= Duration::from_secs(FOLLOW_AGENT_HEARTBEAT_INTERVAL_SECS)
        {
            let _ = store.mark_agent_seen(session_id)?;
            last_agent_seen_refresh = Instant::now();
        }

        let session = store.load(session_id)?;
        let pending_feedback = collect_pending_feedback(&session);
        let signature = current_follow_signature(&session);
        let event_kind = follow_event_kind(&session, &pending_feedback);
        let should_emit = if !emitted_snapshot {
            true
        } else {
            match event_kind {
                AgentEventKind::Snapshot => false,
                AgentEventKind::ReviewerFeedback | AgentEventKind::ReviewerDecision => {
                    last_emitted_signature.as_ref() != Some(&signature)
                }
            }
        };

        if should_emit {
            emit_follow_event(&session, event_kind, pending_feedback)?;
            last_emitted_signature = Some(signature);
            emitted_snapshot = true;

            if matches!(
                session.status,
                SessionStatus::Approved | SessionStatus::Closed
            ) {
                break;
            }
        }

        thread::sleep(Duration::from_millis(WAIT_POLL_INTERVAL_MS));
    }

    Ok(())
}

fn emit_follow_event(
    session: &ReviewSession,
    event_kind: AgentEventKind,
    pending_feedback: Vec<PendingFeedback>,
) -> Result<()> {
    let event = AgentEvent::new(event_kind, session, pending_feedback);
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer(&mut handle, &event)?;
    writeln!(&mut handle)?;
    handle.flush()?;
    Ok(())
}

fn print_wait_result(
    command: CliCommand,
    wait_result: WaitResult,
    json: bool,
    timeout_secs: Option<u64>,
) -> Result<()> {
    match wait_result {
        WaitResult::Ready(session) => print_session(command, &session, json),
        WaitResult::TimedOut(session) => {
            if json {
                if let Some(timeout_secs) = timeout_secs {
                    eprintln!(
                        "warning: timed out waiting for reviewer activity or decision after {timeout_secs}s; returning current session status"
                    );
                }
                return print_session(command, &session, true);
            }

            if let Some(timeout_secs) = timeout_secs {
                bail!("timed out waiting for reviewer activity or decision after {timeout_secs}s");
            }
            bail!("timed out waiting for reviewer activity or decision");
        }
    }
}

fn print_session(command: CliCommand, session: &ReviewSession, json: bool) -> Result<()> {
    if json {
        let payload = CliResponse::new(command, session);
        println!("{}", serde_json::to_string_pretty(&payload)?);
        return Ok(());
    }

    println!("session: {}", session.id);
    println!("repo: {}", session.repo_root);
    println!(
        "mode: {}",
        match session.mode {
            ReviewMode::Branch => "branch",
            ReviewMode::Commit => "commit",
            ReviewMode::Uncommitted => "uncommitted",
        }
    );
    println!("base/head: {}...{}", session.base_ref, session.head_ref);
    println!("merge-base: {}", session.merge_base_sha);
    if let Some(change_summary) = session.change_summary.as_deref() {
        println!("change-summary: {change_summary}");
    }
    println!("status: {:?}", session.status);
    println!("threads: {}", session.threads.len());
    println!("agent-prompt: {}", agent_prompt_command(session));
    println!("agent-follow: {}", agent_follow_command(session));
    println!("agent-wait: {}", agent_wait_command(session));
    if let Some(decision) = &session.decision {
        println!("decision: {:?}", decision.outcome);
    }
    Ok(())
}

fn agent_prompt_command(session: &ReviewSession) -> String {
    format!(
        "{} --repo {} agent prompt --session {}",
        argon_cli_command(),
        shell_quote(&session.repo_root),
        session.id
    )
}

fn reviewer_comment_command_template(session: &ReviewSession, reviewer_name: &str) -> String {
    format!(
        "{} --repo {} reviewer comment --session {} --reviewer {}",
        argon_cli_command(),
        shell_quote(&session.repo_root),
        session.id,
        shell_quote(reviewer_name)
    )
}

fn reviewer_decide_command_template(session: &ReviewSession, reviewer_name: &str) -> String {
    format!(
        "{} --repo {} reviewer decide --session {} --reviewer {} --outcome <changes-requested|commented>",
        argon_cli_command(),
        shell_quote(&session.repo_root),
        session.id,
        shell_quote(reviewer_name)
    )
}

fn reviewer_wait_command(session: &ReviewSession, reviewer_name: &str) -> String {
    format!(
        "{} --repo {} reviewer wait --session {} --reviewer {} --json",
        argon_cli_command(),
        shell_quote(&session.repo_root),
        session.id,
        shell_quote(reviewer_name)
    )
}

fn agent_wait_command(session: &ReviewSession) -> String {
    format!(
        "{} --repo {} agent wait --session {} --json",
        argon_cli_command(),
        shell_quote(&session.repo_root),
        session.id
    )
}

fn agent_follow_command(session: &ReviewSession) -> String {
    format!(
        "{} --repo {} agent follow --session {} --jsonl",
        argon_cli_command(),
        shell_quote(&session.repo_root),
        session.id
    )
}

fn argon_cli_command() -> &'static str {
    ARGON_CLI_COMMAND
        .get_or_init(|| {
            if let Ok(command) = std::env::var("ARGON_CLI_CMD") {
                let trimmed = command.trim();
                if !trimmed.is_empty() {
                    return trimmed.to_string();
                }
            }

            if let Ok(current_exe) = std::env::current_exe() {
                return shell_quote(current_exe.to_string_lossy().as_ref());
            }

            "argon".to_string()
        })
        .as_str()
}

fn shell_quote(raw: &str) -> String {
    let safe = raw
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | ':' | '+'));
    if safe && !raw.is_empty() {
        return raw.to_string();
    }

    format!("'{}'", raw.replace('\'', "'\\''"))
}

fn launch_desktop_app_for_session(repo_root: &Path, session_id: Uuid, launch: &LaunchOptions) {
    if let Err(error) = try_launch_desktop_app_for_session(repo_root, session_id, launch) {
        eprintln!("warning: failed to launch Argon desktop app automatically: {error}");
    }
}

fn launch_desktop_app_for_workspace(target: &WorkspaceLaunchTarget, launch: &LaunchOptions) {
    if let Err(error) = try_launch_desktop_app_for_workspace(target, launch) {
        eprintln!("warning: failed to launch Argon desktop app automatically: {error}");
    }
}

fn try_launch_desktop_app_for_session(
    repo_root: &Path,
    session_id: Uuid,
    launch: &LaunchOptions,
) -> Result<&'static str> {
    let session = session_id.to_string();
    let reviewed_repo = repo_root.to_string_lossy().to_string();
    let launch_args = vec![
        "--session-id".to_string(),
        session.clone(),
        "--repo-root".to_string(),
        reviewed_repo.clone(),
    ];
    let envs = vec![
        ("ARGON_SESSION_ID", session.clone()),
        ("ARGON_REPO_ROOT", reviewed_repo.clone()),
        ("ARGON_CLI_CMD", argon_cli_command().to_string()),
    ];

    if let Some(launcher_path) = launch
        .desktop_launch
        .clone()
        .or_else(|| std::env::var_os("ARGON_DESKTOP_LAUNCH").map(PathBuf::from))
        .map(normalize_path)
        && spawn_desktop_command(Command::new(launcher_path), repo_root, &envs).is_ok()
    {
        return Ok("desktop-launch-flag");
    }

    #[cfg(target_os = "macos")]
    {
        // Try ARGON_APP env var pointing to a specific .app bundle
        if let Some(app_path) = std::env::var_os("ARGON_APP").filter(|v| !v.is_empty()) {
            let app = PathBuf::from(app_path);
            if app.exists()
                && spawn_desktop_command(
                    {
                        let mut command = Command::new("open");
                        command.args(["-a", &app.to_string_lossy()]);
                        command.arg("--args");
                        command.args(&launch_args);
                        command
                    },
                    repo_root,
                    &envs,
                )
                .is_ok()
            {
                return Ok("argon-app-env");
            }
        }

        // Try launching Argon.app via macOS `open` (installed in /Applications or Spotlight-indexed)
        if spawn_desktop_command(
            {
                let mut command = Command::new("open");
                command.args(["-a", "Argon"]);
                command.arg("--args");
                command.args(&launch_args);
                command
            },
            repo_root,
            &envs,
        )
        .is_ok()
        {
            return Ok("macos-open");
        }
    }

    bail!(
        "no compatible launch method found (use --desktop-launch, ARGON_APP, or install Argon.app)"
    )
}

fn try_launch_desktop_app_for_workspace(
    target: &WorkspaceLaunchTarget,
    launch: &LaunchOptions,
) -> Result<&'static str> {
    let repo_root = target.repo_root.to_string_lossy().to_string();
    let repo_common_dir = target.repo_common_dir.to_string_lossy().to_string();
    let selected_worktree = target.selected_worktree_root.to_string_lossy().to_string();
    let launch_args = vec![
        "--workspace-repo-root".to_string(),
        repo_root.clone(),
        "--workspace-common-dir".to_string(),
        repo_common_dir.clone(),
        "--selected-worktree-path".to_string(),
        selected_worktree.clone(),
    ];
    let envs = vec![
        ("ARGON_WORKSPACE_REPO_ROOT", repo_root.clone()),
        ("ARGON_WORKSPACE_COMMON_DIR", repo_common_dir.clone()),
        ("ARGON_SELECTED_WORKTREE_PATH", selected_worktree.clone()),
        ("ARGON_CLI_CMD", argon_cli_command().to_string()),
    ];

    if let Some(launcher_path) = launch
        .desktop_launch
        .clone()
        .or_else(|| std::env::var_os("ARGON_DESKTOP_LAUNCH").map(PathBuf::from))
        .map(normalize_path)
        && spawn_desktop_command(
            Command::new(launcher_path),
            &target.selected_worktree_root,
            &envs,
        )
        .is_ok()
    {
        return Ok("desktop-launch-flag");
    }

    #[cfg(target_os = "macos")]
    {
        if let Some(app_path) = std::env::var_os("ARGON_APP").filter(|v| !v.is_empty()) {
            let app = PathBuf::from(app_path);
            if app.exists()
                && spawn_desktop_command(
                    {
                        let mut command = Command::new("open");
                        command.args(["-a", &app.to_string_lossy()]);
                        command.arg("--args");
                        command.args(&launch_args);
                        command
                    },
                    &target.selected_worktree_root,
                    &envs,
                )
                .is_ok()
            {
                return Ok("argon-app-env");
            }
        }

        if spawn_desktop_command(
            {
                let mut command = Command::new("open");
                command.args(["-a", "Argon"]);
                command.arg("--args");
                command.args(&launch_args);
                command
            },
            &target.selected_worktree_root,
            &envs,
        )
        .is_ok()
        {
            return Ok("macos-open");
        }
    }

    bail!(
        "no compatible launch method found (use --desktop-launch, ARGON_APP, or install Argon.app)"
    )
}

fn spawn_desktop_command(
    mut command: Command,
    launch_cwd: &Path,
    envs: &[(&str, String)],
) -> Result<()> {
    command
        .current_dir(launch_cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    for (key, value) in envs {
        command.env(key, value);
    }
    #[cfg(unix)]
    unsafe {
        // Start the desktop launcher in its own session so it survives after
        // the CLI command that requested it exits.
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command
        .spawn()
        .with_context(|| "failed to spawn desktop launch command".to_string())?;
    Ok(())
}

fn normalize_override_path(path: Option<PathBuf>) -> Option<PathBuf> {
    path.map(normalize_path)
}

fn normalize_path(path: PathBuf) -> PathBuf {
    if path.is_absolute() {
        return path;
    }

    if let Ok(current_dir) = std::env::current_dir() {
        return current_dir.join(path);
    }

    path
}

fn open_store_for_current_repo(runtime: &RuntimeOptions) -> Result<SessionStore> {
    let repo_root = resolved_repo_root(runtime)?;
    Ok(SessionStore::for_repo_root(repo_root))
}

fn resolved_review_repo_root(args: &ReviewArgs, runtime: &RuntimeOptions) -> Result<PathBuf> {
    if let Some(path) = &args.path {
        if runtime.repo_root_override.is_some() {
            bail!("`argon review <dir>` cannot be combined with --repo");
        }
        return git_repo_root_from(path);
    }

    resolved_repo_root(runtime)
}

fn resolved_repo_root(runtime: &RuntimeOptions) -> Result<PathBuf> {
    if let Some(path) = &runtime.repo_root_override {
        return git_repo_root_from(path);
    }

    git_repo_root()
}

fn resolve_workspace_launch_target(path: &Path) -> Result<WorkspaceLaunchTarget> {
    let selected_worktree_root = git_repo_root_from(path)?;
    let repo_common_dir = git_common_dir_from(path)?;
    let repo_root = if repo_common_dir
        .file_name()
        .is_some_and(|name| name == ".git")
    {
        repo_common_dir
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| selected_worktree_root.clone())
    } else {
        selected_worktree_root.clone()
    };

    Ok(WorkspaceLaunchTarget {
        repo_root,
        repo_common_dir,
        selected_worktree_root,
    })
}

fn git_repo_root() -> Result<PathBuf> {
    let current_dir = std::env::current_dir().context("failed to get current directory")?;
    git_repo_root_from(&current_dir)
}

fn git_repo_root_from(path: &Path) -> Result<PathBuf> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .context("failed to execute git rev-parse")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        bail!("git rev-parse --show-toplevel failed: {stderr}");
    }

    let stdout = String::from_utf8(output.stdout).context("git output was not valid UTF-8")?;
    Ok(PathBuf::from(stdout.trim()))
}

fn git_common_dir_from(path: &Path) -> Result<PathBuf> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        .output()
        .context("failed to execute git rev-parse")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        bail!("git rev-parse --git-common-dir failed: {stderr}");
    }

    let stdout = String::from_utf8(output.stdout).context("git output was not valid UTF-8")?;
    Ok(PathBuf::from(stdout.trim()))
}

#[derive(serde::Deserialize)]
struct PrRefs {
    #[serde(rename = "baseRefName")]
    base_ref: String,
    #[serde(rename = "headRefName")]
    head_ref: String,
}

fn pr_refs() -> Result<PrRefs> {
    let output = Command::new("gh")
        .args(["pr", "view", "--json", "baseRefName,headRefName"])
        .output()
        .context("failed to execute gh pr view")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        bail!("gh pr view failed: {stderr}");
    }

    let payload =
        serde_json::from_slice::<PrRefs>(&output.stdout).context("invalid gh pr view JSON")?;
    Ok(payload)
}
