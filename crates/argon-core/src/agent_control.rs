use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FinalizeAction {
    RebaseOntoBase,
    FastForwardToBase,
    MergeCommitToBase,
    RebaseAndMergeToBase,
    SquashAndMergeToBase,
    OpenPullRequest,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentControlStatus {
    Success,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ReviewSummaryDraft {
    pub title: String,
    pub summary: String,
    pub testing: String,
    pub risks: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", content = "action")]
pub enum AgentControlAction {
    ReviewSummary,
    Finalize(FinalizeAction),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentControlRequest {
    pub id: Uuid,
    pub repo_root: String,
    pub worktree_path: String,
    pub branch_name: String,
    pub base_ref: String,
    #[serde(default)]
    pub compare_url: Option<String>,
    pub action: AgentControlAction,
    pub prompt: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AgentControlResponse {
    ReviewSummary {
        request_id: Uuid,
        status: AgentControlStatus,
        message: String,
        draft: Option<ReviewSummaryDraft>,
    },
    Finalize {
        request_id: Uuid,
        action: FinalizeAction,
        status: AgentControlStatus,
        message: String,
        branch_head: Option<String>,
        pull_request_url: Option<String>,
        follow_up: Option<String>,
    },
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use uuid::Uuid;

    use super::*;

    #[test]
    fn review_summary_request_serializes_stable_shape() {
        let request = AgentControlRequest {
            id: Uuid::parse_str("5f44e59d-4ad9-4e53-a835-04bfbb6802eb").unwrap(),
            repo_root: "/tmp/repo".to_string(),
            worktree_path: "/tmp/repo/feature".to_string(),
            branch_name: "feature/window".to_string(),
            base_ref: "origin/main".to_string(),
            compare_url: Some(
                "https://github.com/example/repo/compare/main...feature/window?expand=1"
                    .to_string(),
            ),
            action: AgentControlAction::ReviewSummary,
            prompt: "Draft a concise review summary.".to_string(),
        };

        let value = serde_json::to_value(request).unwrap();
        let expected = json!({
            "id": "5f44e59d-4ad9-4e53-a835-04bfbb6802eb",
            "repo_root": "/tmp/repo",
            "worktree_path": "/tmp/repo/feature",
            "branch_name": "feature/window",
            "base_ref": "origin/main",
            "compare_url": "https://github.com/example/repo/compare/main...feature/window?expand=1",
            "action": {
                "kind": "review_summary"
            },
            "prompt": "Draft a concise review summary."
        });
        assert_eq!(value, expected);
    }

    #[test]
    fn finalize_request_round_trips_from_json() {
        let payload = json!({
            "id": "8170db1f-2a39-4306-b0c0-c80afab0151e",
            "repo_root": "/tmp/repo",
            "worktree_path": "/tmp/repo/feature",
            "branch_name": "feature/window",
            "base_ref": "origin/main",
            "compare_url": null,
            "action": {
                "kind": "finalize",
                "action": "open_pull_request"
            },
            "prompt": "Open the pull request."
        });

        let request: AgentControlRequest = serde_json::from_value(payload).unwrap();
        assert_eq!(request.branch_name, "feature/window");
        assert_eq!(
            request.action,
            AgentControlAction::Finalize(FinalizeAction::OpenPullRequest)
        );
        assert_eq!(request.compare_url, None);
    }

    #[test]
    fn review_summary_response_round_trips_from_json() {
        let payload = json!({
            "kind": "review_summary",
            "request_id": "8170db1f-2a39-4306-b0c0-c80afab0151e",
            "status": "success",
            "message": "Summary drafted from the current diff.",
            "draft": {
                "title": "Add summary-first review flow",
                "summary": "Introduces a review preparation sheet and persists drafts.",
                "testing": "make check",
                "risks": "Need broader UI coverage."
            }
        });

        let response: AgentControlResponse = serde_json::from_value(payload).unwrap();
        match response {
            AgentControlResponse::ReviewSummary {
                status,
                draft,
                message,
                ..
            } => {
                assert_eq!(status, AgentControlStatus::Success);
                assert_eq!(message, "Summary drafted from the current diff.");
                let draft = draft.unwrap();
                assert_eq!(draft.title, "Add summary-first review flow");
            }
            _ => panic!("expected review summary response"),
        }
    }

    #[test]
    fn finalize_response_serializes_stable_shape() {
        let response = AgentControlResponse::Finalize {
            request_id: Uuid::parse_str("5f44e59d-4ad9-4e53-a835-04bfbb6802eb").unwrap(),
            action: FinalizeAction::OpenPullRequest,
            status: AgentControlStatus::Success,
            message: "Opened the pull request and left the branch intact.".to_string(),
            branch_head: Some("abc123".to_string()),
            pull_request_url: Some("https://github.com/example/repo/pull/42".to_string()),
            follow_up: Some("Share the PR with the reviewer.".to_string()),
        };

        let value = serde_json::to_value(response).unwrap();
        let expected = json!({
            "kind": "finalize",
            "request_id": "5f44e59d-4ad9-4e53-a835-04bfbb6802eb",
            "action": "open_pull_request",
            "status": "success",
            "message": "Opened the pull request and left the branch intact.",
            "branch_head": "abc123",
            "pull_request_url": "https://github.com/example/repo/pull/42",
            "follow_up": "Share the PR with the reviewer."
        });
        assert_eq!(value, expected);
    }
}
