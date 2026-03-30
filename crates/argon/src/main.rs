use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use argon_core::{
    AgentEvent, AgentEventKind, CliCommand, CliResponse, CommentAnchor, CommentAuthor, CommentKind,
    PendingFeedback, ResolvedReviewTarget, ReviewComment, ReviewMode, ReviewOutcome, ReviewSession,
    SessionPayload, SessionStatus, SessionStore, ThreadState, auto_detect_review_target,
    resolve_branch_target, resolve_commit_target, resolve_uncommitted_target,
};
use chrono::{DateTime, Utc};
use clap::{Parser, Subcommand, ValueEnum};
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
    description: Option<String>,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Clone, Default)]
struct LaunchOptions {
    desktop_launch: Option<PathBuf>,
    agent_command: Option<String>,
    change_summary: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct RuntimeOptions {
    launch: LaunchOptions,
    repo_root_override: Option<PathBuf>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Review(ReviewArgs),
    #[command(subcommand)]
    Agent(AgentCommands),
    #[command(subcommand)]
    Reviewer(ReviewerCommands),
    Diff(DiffArgs),
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
    json: bool,
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
    let raw_args: Vec<String> = std::env::args().collect();
    if let Some((path, launch)) = maybe_direct_path_invocation(&raw_args) {
        return run_path_review(path, &launch);
    }

    let cli = Cli::parse();
    let runtime = RuntimeOptions {
        launch: LaunchOptions {
            desktop_launch: normalize_override_path(cli.desktop_launch.clone()),
            agent_command: cli.agent.clone(),
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
    if runtime.launch.change_summary.is_some() && !supports_agent_launch {
        bail!(
            "--description is only supported with session-starting commands (`argon <path>`, `argon review`, `argon agent start`)"
        );
    }

    match cli.command {
        Commands::Review(args) => run_review(args, &runtime),
        Commands::Agent(command) => run_agent(command, &runtime),
        Commands::Reviewer(command) => run_reviewer(command, &runtime),
        Commands::Diff(args) => run_diff(args, &runtime),
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
            change_summary,
        },
    ))
}

fn is_command_token(token: &str) -> bool {
    matches!(
        token,
        "review" | "agent" | "reviewer" | "diff" | "draft" | "skill" | "help"
    )
}

fn run_path_review(path: PathBuf, launch: &LaunchOptions) -> Result<()> {
    let repo_root = git_repo_root_from(&path)?;
    let target = auto_detect_review_target(&repo_root)?;
    let store = SessionStore::for_repo_root(repo_root);
    let session = store.create_session_with_details(
        target.mode,
        target.base_ref,
        target.head_ref,
        target.merge_base_sha,
        launch.change_summary.clone(),
    )?;
    launch_desktop_app_for_session(store.repo_root(), session.id, launch);
    maybe_launch_agent_for_session(&session, launch.agent_command.as_deref())?;

    print_session(CliCommand::Review, &session, false)
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
            // Backward compat: if base/head provided, use branch mode
            if args.base.is_some() || args.head.is_some() {
                let base = args.base.as_deref();
                let head = args.head.as_deref();
                if base.is_none() || head.is_none() {
                    bail!("both --base and --head are required for branch mode");
                }
                resolve_branch_target(&repo_root, base, head)?
            } else {
                // Auto-detect
                auto_detect_review_target(&repo_root)?
            }
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
    maybe_launch_agent_for_session(&session, runtime.launch.agent_command.as_deref())?;

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

    let repo_root = resolved_repo_root(runtime)?;
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
    maybe_launch_agent_for_session(&session, runtime.launch.agent_command.as_deref())?;

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
    let _ = store.mark_agent_seen(args.session)?;
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
    let session = store.load(args.session)?;
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
        launch_agent_command(&session, &prompt, &continue_command, template)?;
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
            "named reviewer agents cannot approve a session; leave `commented` or `changes-requested` and let the human make the final approval"
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
        "You may inspect the repo and run tests or other read-only commands to validate the work."
            .to_string(),
    );
    lines.push("Use reviewer comment commands to record actionable findings.".to_string());
    lines.push(format!(
        "Comment template: {comment_command_template} --message \"<comment>\""
    ));
    lines.push(
        "Add --file <path> and optionally --line-old/--line-new when you can anchor the comment to a changed line."
            .to_string(),
    );
    lines.push(
        "When you finish a review round, either leave more comments or submit one decision."
            .to_string(),
    );
    lines.push(format!("Decision template: {decision_command_template}"));
    lines.push(
        "Use `changes-requested` when the agent must make changes. Use `commented` when the pass is clean or when feedback is non-blocking."
            .to_string(),
    );
    lines.push(
        "Do not use `approved`: the human reviewer has the last word and must decide whether to approve or close the session."
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

fn maybe_launch_agent_for_session(session: &ReviewSession, template: Option<&str>) -> Result<()> {
    let Some(template) = template else {
        return Ok(());
    };

    let pending_feedback = collect_pending_feedback(session);
    let continue_command = agent_wait_command(session);
    let prompt = build_agent_prompt(session, &pending_feedback, &continue_command);
    launch_agent_command(session, &prompt, &continue_command, template)
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
        "4) After replying, run the same wait command again and continue this loop.".to_string(),
    );
    lines.push(
        "5) If the wait command returns `approved`, treat that as human approval. If it returns `closed`, the human ended the Argon session. Those are the only terminal states."
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
) -> Result<()> {
    let command = render_agent_launch_command(template, session, prompt, continue_command);
    let status = shell_command(&command)
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

        spawn_desktop_command(command, temp.path(), temp.path(), "test-session", false)
            .expect("spawn desktop command");

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
    loop {
        let session = store.load(session_id)?;
        if session.decision.is_some()
            || matches!(
                session.status,
                SessionStatus::Approved | SessionStatus::AwaitingAgent | SessionStatus::Closed
            )
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

fn wait_for_reviewer_feedback(
    store: &SessionStore,
    session_id: Uuid,
    reviewer_name: &str,
    timeout_secs: Option<u64>,
) -> Result<WaitResult> {
    let started = Instant::now();
    loop {
        let session = store.load(session_id)?;
        if matches!(
            session.status,
            SessionStatus::Approved | SessionStatus::Closed
        ) {
            return Ok(WaitResult::Ready(session));
        }
        let last_seen_at = store.load_reviewer_last_seen(session_id, reviewer_name)?;
        let pending_feedback =
            collect_pending_reviewer_feedback(&session, reviewer_name, last_seen_at);
        if !pending_feedback.is_empty() {
            mark_reviewer_feedback_seen(store, session_id, reviewer_name, &pending_feedback)?;
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
    if let Err(error) = try_launch_desktop_app(repo_root, session_id, launch) {
        eprintln!("warning: failed to launch Argon desktop app automatically: {error}");
    }
}

fn try_launch_desktop_app(
    repo_root: &Path,
    session_id: Uuid,
    launch: &LaunchOptions,
) -> Result<&'static str> {
    let session = session_id.to_string();

    if let Some(launcher_path) = launch
        .desktop_launch
        .clone()
        .or_else(|| std::env::var_os("ARGON_DESKTOP_LAUNCH").map(PathBuf::from))
        .map(normalize_path)
        && spawn_desktop_command(
            Command::new(launcher_path),
            repo_root,
            repo_root,
            &session,
            false,
        )
        .is_ok()
    {
        return Ok("desktop-launch-flag");
    }

    #[cfg(target_os = "macos")]
    {
        let reviewed_repo = repo_root.to_string_lossy().to_string();

        // Try ARGON_APP env var pointing to a specific .app bundle
        if let Some(app_path) = std::env::var_os("ARGON_APP").filter(|v| !v.is_empty()) {
            let app = PathBuf::from(app_path);
            if app.exists()
                && spawn_desktop_command(
                    {
                        let mut command = Command::new("open");
                        command.args(["-a", &app.to_string_lossy()]);
                        command.args([
                            "--args",
                            "--session-id",
                            &session,
                            "--repo-root",
                            &reviewed_repo,
                        ]);
                        command
                    },
                    repo_root,
                    repo_root,
                    &session,
                    false,
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
                command.args([
                    "--args",
                    "--session-id",
                    &session,
                    "--repo-root",
                    &reviewed_repo,
                ]);
                command
            },
            repo_root,
            repo_root,
            &session,
            false,
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
    reviewed_repo_root: &Path,
    session_id: &str,
    inject_cli_args: bool,
) -> Result<()> {
    if inject_cli_args {
        let reviewed_repo = reviewed_repo_root.to_string_lossy().to_string();
        command
            .arg("--session-id")
            .arg(session_id)
            .arg("--repo-root")
            .arg(&reviewed_repo);
    }

    command
        .current_dir(launch_cwd)
        .env("ARGON_SESSION_ID", session_id)
        .env("ARGON_REPO_ROOT", reviewed_repo_root)
        .env("ARGON_CLI_CMD", argon_cli_command())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
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

fn resolved_repo_root(runtime: &RuntimeOptions) -> Result<PathBuf> {
    if let Some(path) = &runtime.repo_root_override {
        return git_repo_root_from(path);
    }

    git_repo_root()
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
