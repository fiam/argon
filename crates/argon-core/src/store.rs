use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use thiserror::Error;
use uuid::Uuid;

use crate::model::{
    CommentAnchor, CommentAuthor, CommentKind, DraftReview, DraftReviewComment, ReviewComment,
    ReviewDecision, ReviewMode, ReviewOutcome, ReviewSession, ReviewThread, SessionStatus,
    ThreadState,
};

#[derive(Debug)]
struct AddComment {
    session_id: Uuid,
    author: CommentAuthor,
    author_name: Option<String>,
    body: String,
    kind: CommentKind,
    anchor: CommentAnchor,
    thread_id: Option<Uuid>,
    addressed: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct ReviewerState {
    reviewer_name: String,
    last_seen_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("session '{0}' was not found")]
    SessionNotFound(Uuid),
    #[error("thread '{thread_id}' was not found in session '{session_id}'")]
    ThreadNotFound { session_id: Uuid, thread_id: Uuid },
    #[error("draft comment '{draft_id}' was not found in session '{session_id}'")]
    DraftCommentNotFound { session_id: Uuid, draft_id: Uuid },
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),
}

#[derive(Debug, Clone)]
pub struct SessionStore {
    repo_root: PathBuf,
    sessions_dir: PathBuf,
}

impl SessionStore {
    pub fn for_repo_root(repo_root: impl Into<PathBuf>) -> Self {
        Self::for_repo_root_with_storage_root(repo_root, argon_storage_root())
    }

    pub fn for_repo_root_with_storage_root(
        repo_root: impl Into<PathBuf>,
        storage_root: impl Into<PathBuf>,
    ) -> Self {
        let repo_root = repo_root.into();
        let sessions_dir = sessions_dir_for_repo(&repo_root, &storage_root.into());
        Self {
            repo_root,
            sessions_dir,
        }
    }

    pub fn repo_root(&self) -> &Path {
        &self.repo_root
    }

    pub fn sessions_dir(&self) -> &Path {
        &self.sessions_dir
    }

    pub fn create_session(
        &self,
        base_ref: impl Into<String>,
        head_ref: impl Into<String>,
        merge_base_sha: impl Into<String>,
    ) -> Result<ReviewSession, StoreError> {
        self.create_session_with_details(
            ReviewMode::Branch,
            base_ref,
            head_ref,
            merge_base_sha,
            None,
        )
    }

    pub fn create_session_with_mode(
        &self,
        mode: ReviewMode,
        base_ref: impl Into<String>,
        head_ref: impl Into<String>,
        merge_base_sha: impl Into<String>,
    ) -> Result<ReviewSession, StoreError> {
        self.create_session_with_details(mode, base_ref, head_ref, merge_base_sha, None)
    }

    pub fn create_session_with_details(
        &self,
        mode: ReviewMode,
        base_ref: impl Into<String>,
        head_ref: impl Into<String>,
        merge_base_sha: impl Into<String>,
        change_summary: Option<String>,
    ) -> Result<ReviewSession, StoreError> {
        let session = ReviewSession::new_with_mode_and_summary(
            mode,
            self.repo_root.to_string_lossy().to_string(),
            base_ref.into(),
            head_ref.into(),
            merge_base_sha.into(),
            change_summary,
        );
        self.save(&session)?;
        Ok(session)
    }

    pub fn update_session_target(
        &self,
        session_id: Uuid,
        mode: ReviewMode,
        base_ref: impl Into<String>,
        head_ref: impl Into<String>,
        merge_base_sha: impl Into<String>,
    ) -> Result<ReviewSession, StoreError> {
        let mut session = self.load(session_id)?;
        session.mode = mode;
        session.base_ref = base_ref.into();
        session.head_ref = head_ref.into();
        session.merge_base_sha = merge_base_sha.into();
        session.status = SessionStatus::AwaitingReviewer;
        session.threads.clear();
        session.decision = None;
        session.touch();
        self.save(&session)?;
        self.remove_draft_review(session_id)?;
        Ok(session)
    }

    pub fn load(&self, session_id: Uuid) -> Result<ReviewSession, StoreError> {
        let path = self.session_path(session_id);
        match read_session_from_path(&path) {
            Ok(session) => Ok(session),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                Err(StoreError::SessionNotFound(session_id))
            }
            Err(error) => Err(StoreError::Io(error)),
        }
    }

    pub fn save(&self, session: &ReviewSession) -> Result<(), StoreError> {
        fs::create_dir_all(&self.sessions_dir)?;

        let session_path = self.session_path(session.id);
        // Use PID + random suffix to avoid temp file collisions between processes
        let temp_name = format!(
            "{}.{}-{}.tmp",
            session.id,
            std::process::id(),
            uuid::Uuid::new_v4().as_fields().0
        );
        let temp_path = self.sessions_dir.join(temp_name);
        let payload = serde_json::to_vec_pretty(session)?;
        fs::write(&temp_path, &payload)?;
        fs::rename(&temp_path, &session_path)?;
        // Clean up temp file if rename failed (shouldn't happen on POSIX)
        let _ = fs::remove_file(&temp_path);
        Ok(())
    }

    pub fn load_draft_review(&self, session_id: Uuid) -> Result<DraftReview, StoreError> {
        let _ = self.load(session_id)?;
        let path = self.draft_review_path(session_id);
        match read_draft_review_from_path(&path) {
            Ok(review) => Ok(review),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                Ok(DraftReview::new(session_id))
            }
            Err(error) => Err(StoreError::Io(error)),
        }
    }

    pub fn upsert_draft_comment(
        &self,
        session_id: Uuid,
        draft_id: Option<Uuid>,
        thread_id: Option<Uuid>,
        body: impl Into<String>,
        anchor: CommentAnchor,
    ) -> Result<DraftReview, StoreError> {
        let _ = self.load(session_id)?;
        let mut draft_review = self.load_draft_review(session_id)?;
        let now = Utc::now();
        let body = body.into();

        if let Some(draft_id) = draft_id {
            let draft = draft_review
                .comments
                .iter_mut()
                .find(|draft| draft.id == draft_id)
                .ok_or(StoreError::DraftCommentNotFound {
                    session_id,
                    draft_id,
                })?;
            draft.thread_id = thread_id;
            draft.anchor = anchor;
            draft.body = body;
            draft.updated_at = now;
        } else if let Some(thread_id) = thread_id {
            if let Some(draft) = draft_review
                .comments
                .iter_mut()
                .find(|draft| draft.thread_id == Some(thread_id))
            {
                draft.anchor = anchor;
                draft.body = body;
                draft.updated_at = now;
            } else {
                draft_review.comments.push(DraftReviewComment {
                    id: Uuid::new_v4(),
                    thread_id: Some(thread_id),
                    anchor,
                    body,
                    created_at: now,
                    updated_at: now,
                });
            }
        } else {
            draft_review.comments.push(DraftReviewComment {
                id: Uuid::new_v4(),
                thread_id: None,
                anchor,
                body,
                created_at: now,
                updated_at: now,
            });
        }

        draft_review.touch();
        self.persist_draft_review(draft_review)
    }

    pub fn delete_draft_comment(
        &self,
        session_id: Uuid,
        draft_id: Uuid,
    ) -> Result<DraftReview, StoreError> {
        let _ = self.load(session_id)?;
        let mut draft_review = self.load_draft_review(session_id)?;
        let initial_len = draft_review.comments.len();
        draft_review.comments.retain(|draft| draft.id != draft_id);
        if draft_review.comments.len() == initial_len {
            return Err(StoreError::DraftCommentNotFound {
                session_id,
                draft_id,
            });
        }

        draft_review.touch();
        self.persist_draft_review(draft_review)
    }

    pub fn submit_draft_review(
        &self,
        session_id: Uuid,
    ) -> Result<(ReviewSession, usize), StoreError> {
        let mut session = self.load(session_id)?;
        let mut draft_review = self.load_draft_review(session_id)?;
        if draft_review.comments.is_empty() {
            self.remove_draft_review(session_id)?;
            return Ok((session, 0));
        }

        draft_review.comments.sort_by_key(|draft| draft.created_at);

        let mut submitted_count = 0;
        for draft in draft_review.comments {
            let kind = if draft.anchor.file_path.is_some()
                || draft.anchor.line_new.is_some()
                || draft.anchor.line_old.is_some()
            {
                CommentKind::Line
            } else {
                CommentKind::Global
            };

            let (next_session, _) = self.add_comment(AddComment {
                session_id,
                author: CommentAuthor::Reviewer,
                author_name: None,
                body: draft.body,
                kind,
                anchor: draft.anchor,
                thread_id: draft.thread_id,
                addressed: false,
            })?;
            session = next_session;
            submitted_count += 1;
        }

        self.remove_draft_review(session_id)?;
        Ok((session, submitted_count))
    }

    pub fn add_reviewer_comment(
        &self,
        session_id: Uuid,
        body: impl Into<String>,
        author_name: Option<String>,
        kind: CommentKind,
        anchor: CommentAnchor,
        thread_id: Option<Uuid>,
    ) -> Result<(ReviewSession, Uuid), StoreError> {
        self.add_comment(AddComment {
            session_id,
            author: CommentAuthor::Reviewer,
            author_name,
            body: body.into(),
            kind,
            anchor,
            thread_id,
            addressed: false,
        })
    }

    pub fn add_agent_reply(
        &self,
        session_id: Uuid,
        thread_id: Uuid,
        body: impl Into<String>,
        addressed: bool,
    ) -> Result<ReviewSession, StoreError> {
        let (session, _) = self.add_comment(AddComment {
            session_id,
            author: CommentAuthor::Agent,
            author_name: None,
            body: body.into(),
            kind: CommentKind::Global,
            anchor: CommentAnchor::default(),
            thread_id: Some(thread_id),
            addressed,
        })?;
        Ok(session)
    }

    pub fn load_reviewer_last_seen(
        &self,
        session_id: Uuid,
        reviewer_name: &str,
    ) -> Result<Option<DateTime<Utc>>, StoreError> {
        let _ = self.load(session_id)?;
        let path = self.reviewer_state_path(session_id, reviewer_name);
        match fs::read(&path) {
            Ok(bytes) => {
                let state: ReviewerState = serde_json::from_slice(&bytes)?;
                Ok(state.last_seen_at)
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(StoreError::Io(error)),
        }
    }

    pub fn mark_reviewer_seen(
        &self,
        session_id: Uuid,
        reviewer_name: &str,
        last_seen_at: Option<DateTime<Utc>>,
    ) -> Result<(), StoreError> {
        let _ = self.load(session_id)?;
        let path = self.reviewer_state_path(session_id, reviewer_name);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let payload = ReviewerState {
            reviewer_name: reviewer_name.to_string(),
            last_seen_at,
        };
        let bytes = serde_json::to_vec_pretty(&payload)?;
        fs::write(path, bytes)?;
        Ok(())
    }

    pub fn mark_thread_resolved(
        &self,
        session_id: Uuid,
        thread_id: Uuid,
    ) -> Result<ReviewSession, StoreError> {
        let mut session = self.load(session_id)?;
        let thread = session
            .threads
            .iter_mut()
            .find(|thread| thread.id == thread_id)
            .ok_or(StoreError::ThreadNotFound {
                session_id,
                thread_id,
            })?;
        thread.state = ThreadState::Resolved;
        thread.agent_acknowledged_at = None;

        if !matches!(
            session.status,
            SessionStatus::Approved | SessionStatus::Closed
        ) {
            session.status = if has_pending_reviewer_feedback(&session) {
                SessionStatus::AwaitingAgent
            } else {
                SessionStatus::AwaitingReviewer
            };
        }

        session.touch();
        self.save(&session)?;
        Ok(session)
    }

    pub fn acknowledge_thread(
        &self,
        session_id: Uuid,
        thread_id: Uuid,
    ) -> Result<ReviewSession, StoreError> {
        let mut session = self.load(session_id)?;
        let now = Utc::now();
        let thread = session
            .threads
            .iter_mut()
            .find(|thread| thread.id == thread_id)
            .ok_or(StoreError::ThreadNotFound {
                session_id,
                thread_id,
            })?;
        thread.agent_acknowledged_at = Some(now);
        session.agent_last_seen_at = Some(now);
        session.touch();
        self.save(&session)?;
        Ok(session)
    }

    pub fn set_decision(
        &self,
        session_id: Uuid,
        outcome: ReviewOutcome,
        summary: Option<String>,
    ) -> Result<ReviewSession, StoreError> {
        let mut session = self.load(session_id)?;
        session.decision = Some(ReviewDecision {
            outcome,
            summary,
            created_at: Utc::now(),
        });
        session.status = match outcome {
            ReviewOutcome::Approved => SessionStatus::Approved,
            ReviewOutcome::ChangesRequested | ReviewOutcome::Commented => {
                SessionStatus::AwaitingAgent
            }
        };
        session.touch();
        self.save(&session)?;
        Ok(session)
    }

    pub fn close_session(&self, session_id: Uuid) -> Result<ReviewSession, StoreError> {
        let mut session = self.load(session_id)?;
        if matches!(
            session.status,
            SessionStatus::Approved | SessionStatus::Closed
        ) {
            return Ok(session);
        }

        session.status = SessionStatus::Closed;
        session.touch();
        self.save(&session)?;
        Ok(session)
    }

    pub fn mark_agent_seen(&self, session_id: Uuid) -> Result<ReviewSession, StoreError> {
        let mut session = self.load(session_id)?;
        session.agent_last_seen_at = Some(Utc::now());
        session.touch();
        self.save(&session)?;
        Ok(session)
    }

    fn add_comment(&self, input: AddComment) -> Result<(ReviewSession, Uuid), StoreError> {
        let mut session = self.load(input.session_id)?;
        let created_at = Utc::now();

        let resolved_thread_id = match input.thread_id {
            Some(thread_id) => {
                let thread = session
                    .threads
                    .iter_mut()
                    .find(|thread| thread.id == thread_id)
                    .ok_or(StoreError::ThreadNotFound {
                        session_id: input.session_id,
                        thread_id,
                    })?;

                let comment = ReviewComment {
                    id: Uuid::new_v4(),
                    thread_id,
                    author: input.author,
                    author_name: input.author_name.clone(),
                    kind: input.kind,
                    anchor: input.anchor,
                    body: input.body,
                    created_at,
                };
                thread.comments.push(comment);
                thread.agent_acknowledged_at = None;
                match input.author {
                    CommentAuthor::Reviewer => {
                        thread.state = ThreadState::Open;
                    }
                    CommentAuthor::Agent => {
                        thread.state = if input.addressed {
                            ThreadState::Addressed
                        } else {
                            ThreadState::Open
                        };
                    }
                }
                thread_id
            }
            None => {
                let new_thread_id = Uuid::new_v4();
                let comment = ReviewComment {
                    id: Uuid::new_v4(),
                    thread_id: new_thread_id,
                    author: input.author,
                    author_name: input.author_name,
                    kind: input.kind,
                    anchor: input.anchor,
                    body: input.body,
                    created_at,
                };
                let thread = ReviewThread {
                    id: new_thread_id,
                    state: ThreadState::Open,
                    agent_acknowledged_at: None,
                    comments: vec![comment],
                };
                session.threads.push(thread);
                new_thread_id
            }
        };

        session.status = match input.author {
            CommentAuthor::Reviewer => SessionStatus::AwaitingAgent,
            CommentAuthor::Agent => {
                session.agent_last_seen_at = Some(Utc::now());
                SessionStatus::AwaitingReviewer
            }
        };
        session.touch();
        self.save(&session)?;
        Ok((session, resolved_thread_id))
    }

    fn session_path(&self, session_id: Uuid) -> PathBuf {
        self.sessions_dir.join(format!("{session_id}.json"))
    }

    fn draft_review_path(&self, session_id: Uuid) -> PathBuf {
        self.sessions_dir
            .join("drafts")
            .join(format!("{session_id}.json"))
    }

    fn reviewer_state_path(&self, session_id: Uuid, reviewer_name: &str) -> PathBuf {
        self.sessions_dir
            .join("reviewers")
            .join(session_id.to_string())
            .join(format!("{}.json", reviewer_state_key(reviewer_name)))
    }

    fn persist_draft_review(&self, draft_review: DraftReview) -> Result<DraftReview, StoreError> {
        if draft_review.comments.is_empty() {
            self.remove_draft_review(draft_review.session_id)?;
            return Ok(draft_review);
        }

        let path = self.draft_review_path(draft_review.session_id);
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::other("draft review path did not have a parent"))?;
        fs::create_dir_all(parent)?;
        let temp_name = format!(
            "draft-{}-{}.tmp",
            std::process::id(),
            uuid::Uuid::new_v4().as_fields().0
        );
        let temp_path = parent.join(temp_name);
        let payload = serde_json::to_vec_pretty(&draft_review)?;
        fs::write(&temp_path, &payload)?;
        fs::rename(&temp_path, &path)?;
        let _ = fs::remove_file(&temp_path);
        Ok(draft_review)
    }

    fn remove_draft_review(&self, session_id: Uuid) -> Result<(), StoreError> {
        let path = self.draft_review_path(session_id);
        match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(StoreError::Io(error)),
        }
    }
}

fn reviewer_state_key(reviewer_name: &str) -> String {
    let trimmed = reviewer_name.trim();
    if trimmed.is_empty() {
        return "reviewer".to_string();
    }

    let mut encoded = String::with_capacity(trimmed.len() * 2);
    for byte in trimmed.as_bytes() {
        encoded.push_str(&format!("{byte:02x}"));
    }
    encoded
}

fn read_session_from_path(path: &Path) -> Result<ReviewSession, io::Error> {
    let payload = fs::read(path)?;
    serde_json::from_slice::<ReviewSession>(&payload)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn read_draft_review_from_path(path: &Path) -> Result<DraftReview, io::Error> {
    let payload = fs::read(path)?;
    serde_json::from_slice::<DraftReview>(&payload)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn sessions_dir_for_repo(repo_root: &Path, storage_root: &Path) -> PathBuf {
    storage_root
        .join("sessions")
        .join(repo_storage_key(repo_root))
}

fn argon_storage_root() -> PathBuf {
    if let Some(path) = non_empty_env_path("ARGON_HOME") {
        return path;
    }

    if let Some(path) = non_empty_env_path("XDG_CACHE_HOME") {
        return path.join("argon");
    }

    if let Some(path) = non_empty_env_path("HOME") {
        return path.join(".cache").join("argon");
    }

    std::env::temp_dir().join("argon")
}

fn non_empty_env_path(name: &str) -> Option<PathBuf> {
    let value = std::env::var_os(name)?;
    if value.is_empty() {
        return None;
    }
    Some(PathBuf::from(value))
}

fn repo_storage_key(repo_root: &Path) -> String {
    let canonical_repo_root =
        fs::canonicalize(repo_root).unwrap_or_else(|_| repo_root.to_path_buf());
    let repo_name = canonical_repo_root
        .file_name()
        .and_then(|name| name.to_str())
        .map(sanitize_repo_name)
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "repo".to_string());
    let repo_path = canonical_repo_root.to_string_lossy();
    let hash = fnv1a64(repo_path.as_bytes());
    format!("{repo_name}-{hash:016x}")
}

fn sanitize_repo_name(name: &str) -> String {
    name.chars()
        .filter_map(|character| {
            let lower = character.to_ascii_lowercase();
            if lower.is_ascii_alphanumeric() || lower == '-' || lower == '_' {
                Some(lower)
            } else {
                None
            }
        })
        .collect()
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn has_pending_reviewer_feedback(session: &ReviewSession) -> bool {
    session.threads.iter().any(|thread| {
        if thread.state != ThreadState::Open {
            return false;
        }
        let Some(latest) = thread.comments.last() else {
            return false;
        };
        latest.author == CommentAuthor::Reviewer
    })
}

#[cfg(test)]
mod tests {
    use tempfile::TempDir;
    use uuid::Uuid;

    use super::*;

    fn test_store(repo_root: &Path) -> SessionStore {
        SessionStore::for_repo_root_with_storage_root(repo_root, repo_root.join(".argon-test-home"))
    }

    #[test]
    fn create_and_load_session() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        let loaded = store.load(session.id).expect("load");
        assert_eq!(loaded.mode, ReviewMode::Branch);
        assert_eq!(loaded.base_ref, "main");
        assert_eq!(loaded.head_ref, "feature/test");
        assert_eq!(loaded.merge_base_sha, "deadbeef");
        assert_eq!(loaded.status, SessionStatus::AwaitingReviewer);
        assert!(loaded.threads.is_empty());
    }

    #[test]
    fn reviewer_comment_persists_author_name() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        let (updated, _thread_id) = store
            .add_reviewer_comment(
                session.id,
                "Please explain this",
                Some("Sherlock".to_string()),
                CommentKind::Global,
                CommentAnchor::default(),
                None,
            )
            .expect("reviewer comment");

        assert_eq!(
            updated.threads[0].comments[0].author_name.as_deref(),
            Some("Sherlock")
        );
        let loaded = store.load(session.id).expect("load");
        assert_eq!(
            loaded.threads[0].comments[0].author_name.as_deref(),
            Some("Sherlock")
        );
    }

    #[test]
    fn reviewer_seen_state_round_trips() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");
        let seen_at = Utc::now();

        store
            .mark_reviewer_seen(session.id, "Sherlock", Some(seen_at))
            .expect("mark reviewer seen");

        let loaded = store
            .load_reviewer_last_seen(session.id, "Sherlock")
            .expect("load reviewer state");
        assert_eq!(loaded, Some(seen_at));
    }

    #[test]
    fn mark_agent_seen_sets_timestamp() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");
        assert!(session.agent_last_seen_at.is_none());

        let updated = store.mark_agent_seen(session.id).expect("mark agent seen");
        assert!(updated.agent_last_seen_at.is_some());
    }

    #[test]
    fn add_agent_reply_fails_for_missing_thread() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        let missing_thread = Uuid::new_v4();
        let error = store
            .add_agent_reply(session.id, missing_thread, "done", true)
            .expect_err("thread should be missing");

        match error {
            StoreError::ThreadNotFound {
                session_id,
                thread_id,
            } => {
                assert_eq!(session_id, session.id);
                assert_eq!(thread_id, missing_thread);
            }
            other => panic!("unexpected error: {other}"),
        }
    }

    #[test]
    fn update_session_target_resets_threads_and_decision() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        let (session, thread_id) = store
            .add_reviewer_comment(
                session.id,
                "Please fix this",
                None,
                CommentKind::Global,
                CommentAnchor::default(),
                None,
            )
            .expect("comment");
        assert_eq!(session.threads.len(), 1);
        assert_eq!(session.threads[0].id, thread_id);

        let session = store
            .set_decision(
                session.id,
                ReviewOutcome::ChangesRequested,
                Some("needs updates".to_string()),
            )
            .expect("decision");
        assert!(session.decision.is_some());

        let session = store
            .update_session_target(session.id, ReviewMode::Commit, "abc123", "def456", "abc123")
            .expect("switch target");
        assert_eq!(session.mode, ReviewMode::Commit);
        assert_eq!(session.base_ref, "abc123");
        assert_eq!(session.head_ref, "def456");
        assert_eq!(session.status, SessionStatus::AwaitingReviewer);
        assert!(session.threads.is_empty());
        assert!(session.decision.is_none());
    }

    #[test]
    fn mark_thread_resolved_updates_thread_state_and_status() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        let (with_thread, thread_id) = store
            .add_reviewer_comment(
                session.id,
                "Please rename this",
                None,
                CommentKind::Global,
                CommentAnchor::default(),
                None,
            )
            .expect("reviewer comment");
        assert_eq!(with_thread.status, SessionStatus::AwaitingAgent);

        let resolved = store
            .mark_thread_resolved(with_thread.id, thread_id)
            .expect("resolve thread");
        assert_eq!(resolved.status, SessionStatus::AwaitingReviewer);
        assert_eq!(resolved.threads.len(), 1);
        assert_eq!(resolved.threads[0].state, ThreadState::Resolved);
    }

    #[test]
    fn mark_thread_resolved_fails_for_missing_thread() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        let missing_thread = Uuid::new_v4();
        let error = store
            .mark_thread_resolved(session.id, missing_thread)
            .expect_err("thread should be missing");

        match error {
            StoreError::ThreadNotFound {
                session_id,
                thread_id,
            } => {
                assert_eq!(session_id, session.id);
                assert_eq!(thread_id, missing_thread);
            }
            other => panic!("unexpected error: {other}"),
        }
    }

    #[test]
    fn acknowledge_thread_sets_timestamp_and_agent_seen() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");
        let (with_thread, thread_id) = store
            .add_reviewer_comment(
                session.id,
                "Please explain this",
                None,
                CommentKind::Global,
                CommentAnchor::default(),
                None,
            )
            .expect("reviewer comment");
        assert!(with_thread.threads[0].agent_acknowledged_at.is_none());

        let acknowledged = store
            .acknowledge_thread(with_thread.id, thread_id)
            .expect("acknowledge thread");
        assert!(acknowledged.agent_last_seen_at.is_some());
        assert_eq!(acknowledged.threads.len(), 1);
        assert!(acknowledged.threads[0].agent_acknowledged_at.is_some());
    }

    #[test]
    fn close_session_marks_status_closed() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");
        let session = store
            .add_reviewer_comment(
                session.id,
                "Please explain this",
                None,
                CommentKind::Global,
                CommentAnchor::default(),
                None,
            )
            .expect("reviewer comment")
            .0;

        let closed = store.close_session(session.id).expect("close session");
        assert_eq!(closed.status, SessionStatus::Closed);
        assert_eq!(closed.threads.len(), 1);
    }

    #[test]
    fn close_session_keeps_approved_sessions_approved() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");
        let approved = store
            .set_decision(
                session.id,
                ReviewOutcome::Approved,
                Some("done".to_string()),
            )
            .expect("approve session");

        let closed = store.close_session(approved.id).expect("close session");
        assert_eq!(closed.status, SessionStatus::Approved);
        assert!(closed.decision.is_some());
    }

    #[test]
    fn acknowledge_thread_fails_for_missing_thread() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        let missing_thread = Uuid::new_v4();
        let error = store
            .acknowledge_thread(session.id, missing_thread)
            .expect_err("thread should be missing");

        match error {
            StoreError::ThreadNotFound {
                session_id,
                thread_id,
            } => {
                assert_eq!(session_id, session.id);
                assert_eq!(thread_id, missing_thread);
            }
            other => panic!("unexpected error: {other}"),
        }
    }

    #[test]
    fn add_comment_clears_thread_acknowledgement() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");
        let (with_thread, thread_id) = store
            .add_reviewer_comment(
                session.id,
                "Please explain this",
                None,
                CommentKind::Global,
                CommentAnchor::default(),
                None,
            )
            .expect("reviewer comment");
        let acknowledged = store
            .acknowledge_thread(with_thread.id, thread_id)
            .expect("acknowledge thread");
        assert!(acknowledged.threads[0].agent_acknowledged_at.is_some());

        let replied = store
            .add_agent_reply(
                acknowledged.id,
                thread_id,
                "Explained in latest update",
                true,
            )
            .expect("agent reply");
        assert_eq!(replied.threads[0].state, ThreadState::Addressed);
        assert!(replied.threads[0].agent_acknowledged_at.is_none());
    }

    #[test]
    fn create_session_does_not_create_repo_local_argon_directory() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        let repo_local_dir = temp_dir.path().join(".argon");
        assert!(!repo_local_dir.exists());
        assert!(store.session_path(session.id).exists());
    }

    #[test]
    fn upsert_and_delete_draft_comment_persists_review_batch() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        let draft_review = store
            .upsert_draft_comment(
                session.id,
                None,
                None,
                "Please rename this",
                CommentAnchor {
                    file_path: Some("src/lib.rs".to_string()),
                    line_new: Some(12),
                    line_old: None,
                },
            )
            .expect("create draft");
        assert_eq!(draft_review.comments.len(), 1);
        let draft_id = draft_review.comments[0].id;

        let loaded = store
            .load_draft_review(session.id)
            .expect("load draft review");
        assert_eq!(loaded.comments.len(), 1);
        assert_eq!(loaded.comments[0].body, "Please rename this");

        let updated = store
            .upsert_draft_comment(
                session.id,
                Some(draft_id),
                None,
                "Please rename this helper",
                CommentAnchor {
                    file_path: Some("src/lib.rs".to_string()),
                    line_new: Some(14),
                    line_old: None,
                },
            )
            .expect("update draft");
        assert_eq!(updated.comments.len(), 1);
        assert_eq!(updated.comments[0].body, "Please rename this helper");
        assert_eq!(updated.comments[0].anchor.line_new, Some(14));

        let emptied = store
            .delete_draft_comment(session.id, draft_id)
            .expect("delete draft comment");
        assert!(emptied.comments.is_empty());
        assert!(
            !store.draft_review_path(session.id).exists(),
            "empty draft reviews should be removed from disk"
        );
    }

    #[test]
    fn submit_draft_review_materializes_comments_and_clears_draft_file() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        store
            .upsert_draft_comment(
                session.id,
                None,
                None,
                "Please explain this branch",
                CommentAnchor::default(),
            )
            .expect("create draft");

        let (submitted_session, submitted_count) = store
            .submit_draft_review(session.id)
            .expect("submit draft review");
        assert_eq!(submitted_count, 1);
        assert_eq!(submitted_session.status, SessionStatus::AwaitingAgent);
        assert_eq!(submitted_session.threads.len(), 1);
        assert_eq!(
            submitted_session.threads[0].comments[0].body,
            "Please explain this branch"
        );
        assert!(
            !store.draft_review_path(session.id).exists(),
            "submitting draft review should clear the draft file"
        );
        assert!(
            store
                .load_draft_review(session.id)
                .expect("reload draft review")
                .comments
                .is_empty()
        );
    }

    #[test]
    fn update_session_target_clears_draft_review() {
        let temp_dir = TempDir::new().expect("temp dir");
        let store = test_store(temp_dir.path());
        let session = store
            .create_session("main", "feature/test", "deadbeef")
            .expect("session");

        store
            .upsert_draft_comment(
                session.id,
                None,
                None,
                "Please rename this",
                CommentAnchor::default(),
            )
            .expect("create draft");
        assert!(store.draft_review_path(session.id).exists());

        store
            .update_session_target(session.id, ReviewMode::Commit, "abc123", "def456", "abc123")
            .expect("switch target");

        assert!(!store.draft_review_path(session.id).exists());
        assert!(
            store
                .load_draft_review(session.id)
                .expect("reload draft review")
                .comments
                .is_empty()
        );
    }
}
