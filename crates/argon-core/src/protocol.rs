use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::model::{
    CommentAnchor, ReviewDecision, ReviewMode, ReviewSession, ReviewThread, SessionStatus,
};

pub const SCHEMA_VERSION: &str = "v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CliCommand {
    Start,
    Review,
    Wait,
    Follow,
    Status,
    Close,
    Reply,
    Ack,
    Prompt,
    ReviewerPrompt,
    ReviewerWait,
    ReviewerComment,
    ReviewerDecide,
    SkillInstall,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentEventKind {
    Snapshot,
    ReviewerFeedback,
    ReviewerDecision,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingFeedback {
    pub thread_id: Uuid,
    pub anchor: CommentAnchor,
    pub reviewer_comment: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPayload {
    pub id: Uuid,
    pub repo_root: String,
    pub mode: ReviewMode,
    pub base_ref: String,
    pub head_ref: String,
    pub merge_base_sha: String,
    pub change_summary: Option<String>,
    pub status: SessionStatus,
    pub threads: Vec<ReviewThread>,
    pub decision: Option<ReviewDecision>,
    pub agent_last_seen_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl From<&ReviewSession> for SessionPayload {
    fn from(session: &ReviewSession) -> Self {
        Self {
            id: session.id,
            repo_root: session.repo_root.clone(),
            mode: session.mode,
            base_ref: session.base_ref.clone(),
            head_ref: session.head_ref.clone(),
            merge_base_sha: session.merge_base_sha.clone(),
            change_summary: session.change_summary.clone(),
            status: session.status,
            threads: session.threads.clone(),
            decision: session.decision.clone(),
            agent_last_seen_at: session.agent_last_seen_at,
            created_at: session.created_at,
            updated_at: session.updated_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CliResponse {
    pub schema_version: String,
    pub command: CliCommand,
    pub session: SessionPayload,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentEvent {
    pub schema_version: String,
    pub command: CliCommand,
    pub event: AgentEventKind,
    pub session: SessionPayload,
    pub pending_feedback: Vec<PendingFeedback>,
}

impl AgentEvent {
    pub fn new(
        event: AgentEventKind,
        session: &ReviewSession,
        pending_feedback: Vec<PendingFeedback>,
    ) -> Self {
        Self {
            schema_version: SCHEMA_VERSION.to_string(),
            command: CliCommand::Follow,
            event,
            session: SessionPayload::from(session),
            pending_feedback,
        }
    }
}

impl CliResponse {
    pub fn new(command: CliCommand, session: &ReviewSession) -> Self {
        Self {
            schema_version: SCHEMA_VERSION.to_string(),
            command,
            session: SessionPayload::from(session),
        }
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;
    use serde_json::json;
    use uuid::Uuid;

    use crate::model::{CommentAnchor, ReviewMode, ReviewOutcome, SessionStatus};

    use super::*;

    fn fixed_timestamp() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 3, 3, 12, 0, 0).single().expect("valid fixed timestamp")
    }

    #[test]
    fn cli_response_serializes_v1_contract_shape() {
        let timestamp = fixed_timestamp();
        let session = ReviewSession {
            id: Uuid::parse_str("5f44e59d-4ad9-4e53-a835-04bfbb6802eb").expect("valid uuid"),
            repo_root: "/tmp/repo".to_string(),
            mode: ReviewMode::Branch,
            base_ref: "main".to_string(),
            head_ref: "feature/refactor".to_string(),
            merge_base_sha: "abc123".to_string(),
            change_summary: Some("Update the parser and tighten tests".to_string()),
            status: SessionStatus::Approved,
            threads: Vec::new(),
            decision: Some(ReviewDecision {
                outcome: ReviewOutcome::Approved,
                summary: Some("Looks good".to_string()),
                created_at: timestamp,
            }),
            agent_last_seen_at: None,
            created_at: timestamp,
            updated_at: timestamp,
        };

        let response = CliResponse::new(CliCommand::Wait, &session);
        let value = serde_json::to_value(response).expect("serialize");

        let expected = json!({
            "schema_version": "v1",
            "command": "wait",
            "session": {
                "id": "5f44e59d-4ad9-4e53-a835-04bfbb6802eb",
                "repo_root": "/tmp/repo",
                "mode": "branch",
                "base_ref": "main",
                "head_ref": "feature/refactor",
                "merge_base_sha": "abc123",
                "change_summary": "Update the parser and tighten tests",
                "status": "approved",
                "threads": [],
                    "decision": {
                        "outcome": "approved",
                        "summary": "Looks good",
                        "created_at": "2026-03-03T12:00:00Z"
                    },
                    "agent_last_seen_at": null,
                    "created_at": "2026-03-03T12:00:00Z",
                    "updated_at": "2026-03-03T12:00:00Z"
                }
        });
        assert_eq!(value, expected);
    }

    #[test]
    fn cli_response_round_trips_from_json() {
        let payload = json!({
            "schema_version": "v1",
            "command": "status",
            "session": {
                "id": "8170db1f-2a39-4306-b0c0-c80afab0151e",
                "repo_root": "/tmp/repo",
                "mode": "uncommitted",
                "base_ref": "HEAD",
                "head_ref": "WORKTREE",
                "merge_base_sha": "abc123",
                "change_summary": null,
                "status": "awaiting_reviewer",
                "threads": [],
                "decision": null,
                "agent_last_seen_at": null,
                "created_at": "2026-03-03T12:00:00Z",
                "updated_at": "2026-03-03T12:00:00Z"
            }
        });

        let response: CliResponse = serde_json::from_value(payload).expect("deserialize");
        assert_eq!(response.schema_version, "v1");
        assert_eq!(response.command, CliCommand::Status);
        assert_eq!(response.session.mode, ReviewMode::Uncommitted);
        assert_eq!(response.session.status, SessionStatus::AwaitingReviewer);
    }

    #[test]
    fn agent_event_serializes_v1_contract_shape() {
        let timestamp = fixed_timestamp();
        let session = ReviewSession {
            id: Uuid::parse_str("5f44e59d-4ad9-4e53-a835-04bfbb6802eb").expect("valid uuid"),
            repo_root: "/tmp/repo".to_string(),
            mode: ReviewMode::Branch,
            base_ref: "main".to_string(),
            head_ref: "feature/refactor".to_string(),
            merge_base_sha: "abc123".to_string(),
            change_summary: None,
            status: SessionStatus::AwaitingAgent,
            threads: Vec::new(),
            decision: None,
            agent_last_seen_at: None,
            created_at: timestamp,
            updated_at: timestamp,
        };
        let payload = AgentEvent::new(
            AgentEventKind::ReviewerFeedback,
            &session,
            vec![PendingFeedback {
                thread_id: Uuid::parse_str("8170db1f-2a39-4306-b0c0-c80afab0151e")
                    .expect("valid uuid"),
                anchor: CommentAnchor {
                    file_path: Some("src/main.rs".to_string()),
                    line_new: Some(14),
                    line_old: Some(10),
                },
                reviewer_comment: "Please explain this".to_string(),
            }],
        );

        let value = serde_json::to_value(payload).expect("serialize");
        let expected = json!({
            "schema_version": "v1",
            "command": "follow",
            "event": "reviewer_feedback",
            "session": {
                "id": "5f44e59d-4ad9-4e53-a835-04bfbb6802eb",
                "repo_root": "/tmp/repo",
                "mode": "branch",
                "base_ref": "main",
                "head_ref": "feature/refactor",
                "merge_base_sha": "abc123",
                "change_summary": null,
                "status": "awaiting_agent",
                "threads": [],
                "decision": null,
                "agent_last_seen_at": null,
                "created_at": "2026-03-03T12:00:00Z",
                "updated_at": "2026-03-03T12:00:00Z"
            },
            "pending_feedback": [{
                "thread_id": "8170db1f-2a39-4306-b0c0-c80afab0151e",
                "anchor": {
                    "file_path": "src/main.rs",
                    "line_new": 14,
                    "line_old": 10
                },
                "reviewer_comment": "Please explain this"
            }]
        });
        assert_eq!(value, expected);
    }
}
