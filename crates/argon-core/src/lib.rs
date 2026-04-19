pub mod diff;
pub mod highlight;
pub mod model;
pub mod protocol;
pub mod store;
pub mod target;

pub use diff::{
    DiffError, DiffHunk, DiffLine, DiffLineKind, FileDiff, ReviewDiff, anchor_at,
    anchor_for_diff_line, build_review_diff, parse_unified_diff,
};
pub use highlight::{
    HighlightedDiff, HighlightedFileDiff, HighlightedHunk, HighlightedLine, SideBySidePair,
    StyledSpan, available_themes, highlight_diff, highlight_text, theme_for_appearance,
};
pub use model::{
    CommentAnchor, CommentAuthor, CommentKind, DraftReview, DraftReviewComment, ReviewComment,
    ReviewDecision, ReviewMode, ReviewOutcome, ReviewSession, ReviewThread, SessionStatus,
    ThreadState,
};
pub use protocol::{
    AgentEvent, AgentEventKind, CliCommand, CliResponse, PendingFeedback, SCHEMA_VERSION,
    SessionPayload,
};
pub use store::{SessionStore, StoreError};
pub use target::{
    ResolvedReviewTarget, TargetError, auto_detect_review_target, current_branch_name, git_capture,
    infer_base_ref, resolve_branch_target, resolve_commit_target, resolve_ref,
    resolve_uncommitted_target,
};
