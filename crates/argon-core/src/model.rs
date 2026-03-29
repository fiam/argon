use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    AwaitingReviewer,
    AwaitingAgent,
    Approved,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewMode {
    Branch,
    Commit,
    Uncommitted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadState {
    Open,
    Addressed,
    Resolved,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommentAuthor {
    Reviewer,
    Agent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommentKind {
    Line,
    Global,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewOutcome {
    Approved,
    ChangesRequested,
    Commented,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewDecision {
    pub outcome: ReviewOutcome,
    pub summary: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct CommentAnchor {
    pub file_path: Option<String>,
    pub line_new: Option<u32>,
    pub line_old: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewComment {
    pub id: Uuid,
    pub thread_id: Uuid,
    pub author: CommentAuthor,
    #[serde(default)]
    pub author_name: Option<String>,
    pub kind: CommentKind,
    pub anchor: CommentAnchor,
    pub body: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftReviewComment {
    pub id: Uuid,
    pub thread_id: Option<Uuid>,
    pub anchor: CommentAnchor,
    pub body: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewThread {
    pub id: Uuid,
    pub state: ThreadState,
    pub agent_acknowledged_at: Option<DateTime<Utc>>,
    pub comments: Vec<ReviewComment>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewSession {
    pub id: Uuid,
    pub repo_root: String,
    pub mode: ReviewMode,
    pub base_ref: String,
    pub head_ref: String,
    pub merge_base_sha: String,
    #[serde(default)]
    pub change_summary: Option<String>,
    pub status: SessionStatus,
    pub threads: Vec<ReviewThread>,
    pub decision: Option<ReviewDecision>,
    pub agent_last_seen_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftReview {
    pub session_id: Uuid,
    pub comments: Vec<DraftReviewComment>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl ReviewSession {
    pub fn new(
        repo_root: String,
        base_ref: String,
        head_ref: String,
        merge_base_sha: String,
    ) -> Self {
        Self::new_with_mode(
            ReviewMode::Branch,
            repo_root,
            base_ref,
            head_ref,
            merge_base_sha,
        )
    }

    pub fn new_with_mode(
        mode: ReviewMode,
        repo_root: String,
        base_ref: String,
        head_ref: String,
        merge_base_sha: String,
    ) -> Self {
        Self::new_with_mode_and_summary(mode, repo_root, base_ref, head_ref, merge_base_sha, None)
    }

    pub fn new_with_mode_and_summary(
        mode: ReviewMode,
        repo_root: String,
        base_ref: String,
        head_ref: String,
        merge_base_sha: String,
        change_summary: Option<String>,
    ) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::new_v4(),
            repo_root,
            mode,
            base_ref,
            head_ref,
            merge_base_sha,
            change_summary,
            status: SessionStatus::AwaitingReviewer,
            threads: Vec::new(),
            decision: None,
            agent_last_seen_at: None,
            created_at: now,
            updated_at: now,
        }
    }

    pub fn touch(&mut self) {
        self.updated_at = Utc::now();
    }
}

impl DraftReview {
    pub fn new(session_id: Uuid) -> Self {
        let now = Utc::now();
        Self {
            session_id,
            comments: Vec::new(),
            created_at: now,
            updated_at: now,
        }
    }

    pub fn touch(&mut self) {
        self.updated_at = Utc::now();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uncommitted_mode_serializes_correctly() {
        let json = serde_json::to_string(&ReviewMode::Uncommitted).unwrap();
        assert_eq!(json, "\"uncommitted\"");
        let deserialized: ReviewMode = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized, ReviewMode::Uncommitted);
    }

    #[test]
    fn session_defaults_to_awaiting_reviewer() {
        let session = ReviewSession::new(
            "/tmp/repo".into(),
            "main".into(),
            "feature".into(),
            "abc123".into(),
        );
        assert_eq!(session.status, SessionStatus::AwaitingReviewer);
        assert!(session.threads.is_empty());
        assert!(session.decision.is_none());
    }
}
