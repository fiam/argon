use std::os::raw::c_char;
use std::path::Path;

use argon_core::{
    CommentAnchor, CommentKind, ResolvedReviewTarget, ReviewMode, ReviewOutcome, SessionStore,
    auto_detect_review_target, resolve_branch_target, resolve_uncommitted_target,
};
use uuid::Uuid;

use crate::{
    clear_error, owned_c_string, review_mode_from_c_pointer, set_error, string_from_c_pointer,
};

#[repr(C)]
pub struct ArgonReviewTarget {
    pub session_id: *mut c_char,
    pub repo_root: *mut c_char,
}

/// Create an Argon review session without shelling out to the CLI.
///
/// # Safety
///
/// All string pointers must be null or point to valid NUL-terminated C strings.
/// The returned pointer must be released with `argonlib_review_target_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_review_create_session(
    repo_root: *const c_char,
    mode: *const c_char,
    base_ref: *const c_char,
    head_ref: *const c_char,
    merge_base_sha: *const c_char,
    change_summary: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut ArgonReviewTarget {
    unsafe {
        clear_error(error_out);
    }

    match create_review_session(
        repo_root,
        mode,
        base_ref,
        head_ref,
        merge_base_sha,
        change_summary,
    ) {
        Ok(target) => Box::into_raw(Box::new(target)),
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            std::ptr::null_mut()
        }
    }
}

/// Free a review target returned by `argonlib_review_create_session`.
///
/// # Safety
///
/// `value` must be null or a pointer returned by
/// `argonlib_review_create_session`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_review_target_free(value: *mut ArgonReviewTarget) {
    if value.is_null() {
        return;
    }

    let value = unsafe { Box::from_raw(value) };
    unsafe {
        crate::argonlib_string_free(value.session_id);
        crate::argonlib_string_free(value.repo_root);
    }
}

/// Update the target for an existing review session.
///
/// # Safety
///
/// All string pointers must point to valid NUL-terminated C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_review_update_session_target(
    repo_root: *const c_char,
    session_id: *const c_char,
    mode: *const c_char,
    base_ref: *const c_char,
    head_ref: *const c_char,
    merge_base_sha: *const c_char,
    error_out: *mut *mut c_char,
) -> bool {
    unsafe {
        clear_error(error_out);
    }

    match update_session_target(
        repo_root,
        session_id,
        mode,
        base_ref,
        head_ref,
        merge_base_sha,
    ) {
        Ok(()) => true,
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            false
        }
    }
}

/// Close an existing review session.
///
/// # Safety
///
/// All string pointers must point to valid NUL-terminated C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_review_close_session(
    repo_root: *const c_char,
    session_id: *const c_char,
    error_out: *mut *mut c_char,
) -> bool {
    unsafe {
        clear_error(error_out);
    }

    match close_session(repo_root, session_id) {
        Ok(()) => true,
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            false
        }
    }
}

/// Add or update a draft review comment.
///
/// # Safety
///
/// All string pointers must be null or point to valid NUL-terminated C strings,
/// except `repo_root`, `session_id`, and `message`, which are required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_review_add_draft_comment(
    repo_root: *const c_char,
    session_id: *const c_char,
    message: *const c_char,
    file_path: *const c_char,
    line_new_present: bool,
    line_new: u32,
    line_old_present: bool,
    line_old: u32,
    thread_id: *const c_char,
    error_out: *mut *mut c_char,
) -> bool {
    unsafe {
        clear_error(error_out);
    }

    let input = CommentInput {
        repo_root,
        session_id,
        message,
        file_path,
        line_new_present,
        line_new,
        line_old_present,
        line_old,
        thread_id,
    };

    match add_draft_comment(input) {
        Ok(()) => true,
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            false
        }
    }
}

/// Delete a draft review comment.
///
/// # Safety
///
/// All string pointers must point to valid NUL-terminated C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_review_delete_draft_comment(
    repo_root: *const c_char,
    session_id: *const c_char,
    draft_id: *const c_char,
    error_out: *mut *mut c_char,
) -> bool {
    unsafe {
        clear_error(error_out);
    }

    match delete_draft_comment(repo_root, session_id, draft_id) {
        Ok(()) => true,
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            false
        }
    }
}

/// Submit all draft review comments and optionally record a decision.
///
/// # Safety
///
/// All string pointers must be null or point to valid NUL-terminated C strings,
/// except `repo_root` and `session_id`, which are required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_review_submit_draft_review(
    repo_root: *const c_char,
    session_id: *const c_char,
    outcome: *const c_char,
    summary: *const c_char,
    error_out: *mut *mut c_char,
) -> bool {
    unsafe {
        clear_error(error_out);
    }

    match submit_draft_review(repo_root, session_id, outcome, summary) {
        Ok(()) => true,
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            false
        }
    }
}

/// Add a human reviewer comment to a review session.
///
/// # Safety
///
/// All string pointers must be null or point to valid NUL-terminated C strings,
/// except `repo_root`, `session_id`, and `message`, which are required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_review_add_comment(
    repo_root: *const c_char,
    session_id: *const c_char,
    message: *const c_char,
    file_path: *const c_char,
    line_new_present: bool,
    line_new: u32,
    line_old_present: bool,
    line_old: u32,
    thread_id: *const c_char,
    error_out: *mut *mut c_char,
) -> bool {
    unsafe {
        clear_error(error_out);
    }

    let input = CommentInput {
        repo_root,
        session_id,
        message,
        file_path,
        line_new_present,
        line_new,
        line_old_present,
        line_old,
        thread_id,
    };

    match add_comment(input) {
        Ok(()) => true,
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            false
        }
    }
}

/// Mark a review thread as resolved.
///
/// # Safety
///
/// All string pointers must point to valid NUL-terminated C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_review_resolve_thread(
    repo_root: *const c_char,
    session_id: *const c_char,
    thread_id: *const c_char,
    error_out: *mut *mut c_char,
) -> bool {
    unsafe {
        clear_error(error_out);
    }

    match resolve_thread(repo_root, session_id, thread_id) {
        Ok(()) => true,
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            false
        }
    }
}

struct CommentInput {
    repo_root: *const c_char,
    session_id: *const c_char,
    message: *const c_char,
    file_path: *const c_char,
    line_new_present: bool,
    line_new: u32,
    line_old_present: bool,
    line_old: u32,
    thread_id: *const c_char,
}

fn create_review_session(
    repo_root: *const c_char,
    mode: *const c_char,
    base_ref: *const c_char,
    head_ref: *const c_char,
    merge_base_sha: *const c_char,
    change_summary: *const c_char,
) -> Result<ArgonReviewTarget, String> {
    let repo_root = required_string(repo_root, "repo root")?;
    let target = resolve_review_target(
        &repo_root,
        optional_nonempty_string(mode).as_deref(),
        optional_nonempty_string(base_ref).as_deref(),
        optional_nonempty_string(head_ref).as_deref(),
        optional_nonempty_string(merge_base_sha).as_deref(),
    )?;
    let store = SessionStore::for_repo_root(&repo_root);
    let session = store
        .create_session_with_details(
            target.mode,
            target.base_ref,
            target.head_ref,
            target.merge_base_sha,
            optional_nonempty_string(change_summary),
        )
        .map_err(|error| format!("failed to create review session: {error}"))?;

    Ok(ArgonReviewTarget {
        session_id: owned_c_string(session.id.to_string()),
        repo_root: owned_c_string(session.repo_root),
    })
}

fn update_session_target(
    repo_root: *const c_char,
    session_id: *const c_char,
    mode: *const c_char,
    base_ref: *const c_char,
    head_ref: *const c_char,
    merge_base_sha: *const c_char,
) -> Result<(), String> {
    let store = store_from_repo_root(repo_root)?;
    let session_id = required_uuid(session_id, "session id")?;
    let mode = review_mode_from_c_pointer(mode)?;
    let base_ref = required_string(base_ref, "base ref")?;
    let head_ref = required_string(head_ref, "head ref")?;
    let merge_base_sha = required_string(merge_base_sha, "merge base sha")?;
    store
        .update_session_target(session_id, mode, base_ref, head_ref, merge_base_sha)
        .map(|_| ())
        .map_err(|error| format!("failed to update session target: {error}"))
}

fn close_session(repo_root: *const c_char, session_id: *const c_char) -> Result<(), String> {
    let store = store_from_repo_root(repo_root)?;
    let session_id = required_uuid(session_id, "session id")?;
    store
        .close_session(session_id)
        .map(|_| ())
        .map_err(|error| format!("failed to close session: {error}"))
}

fn add_draft_comment(input: CommentInput) -> Result<(), String> {
    let store = store_from_repo_root(input.repo_root)?;
    let session_id = required_uuid(input.session_id, "session id")?;
    let thread_id = optional_uuid(input.thread_id, "thread id")?;
    let message = required_string(input.message, "message")?;
    let anchor = comment_anchor(&input);
    store
        .upsert_draft_comment(session_id, None, thread_id, message, anchor)
        .map(|_| ())
        .map_err(|error| format!("failed to add draft comment: {error}"))
}

fn delete_draft_comment(
    repo_root: *const c_char,
    session_id: *const c_char,
    draft_id: *const c_char,
) -> Result<(), String> {
    let store = store_from_repo_root(repo_root)?;
    let session_id = required_uuid(session_id, "session id")?;
    let draft_id = required_uuid(draft_id, "draft id")?;
    store
        .delete_draft_comment(session_id, draft_id)
        .map(|_| ())
        .map_err(|error| format!("failed to delete draft comment: {error}"))
}

fn submit_draft_review(
    repo_root: *const c_char,
    session_id: *const c_char,
    outcome: *const c_char,
    summary: *const c_char,
) -> Result<(), String> {
    let store = store_from_repo_root(repo_root)?;
    let session_id = required_uuid(session_id, "session id")?;
    let (session, _) = store
        .submit_draft_review(session_id)
        .map_err(|error| format!("failed to submit draft review: {error}"))?;
    if let Some(outcome) = optional_outcome(outcome)? {
        store
            .set_decision(session.id, outcome, optional_nonempty_string(summary))
            .map_err(|error| format!("failed to set review decision: {error}"))?;
    }
    Ok(())
}

fn add_comment(input: CommentInput) -> Result<(), String> {
    let store = store_from_repo_root(input.repo_root)?;
    let session_id = required_uuid(input.session_id, "session id")?;
    let thread_id = optional_uuid(input.thread_id, "thread id")?;
    let message = required_string(input.message, "message")?;
    let kind = comment_kind(&input);
    let anchor = comment_anchor(&input);
    store
        .add_reviewer_comment(session_id, message, None, kind, anchor, thread_id)
        .map(|_| ())
        .map_err(|error| format!("failed to add review comment: {error}"))
}

fn resolve_thread(
    repo_root: *const c_char,
    session_id: *const c_char,
    thread_id: *const c_char,
) -> Result<(), String> {
    let store = store_from_repo_root(repo_root)?;
    let session_id = required_uuid(session_id, "session id")?;
    let thread_id = required_uuid(thread_id, "thread id")?;
    store
        .mark_thread_resolved(session_id, thread_id)
        .map(|_| ())
        .map_err(|error| format!("failed to resolve thread: {error}"))
}

fn resolve_review_target(
    repo_root: &str,
    mode: Option<&str>,
    base_ref: Option<&str>,
    head_ref: Option<&str>,
    merge_base_sha: Option<&str>,
) -> Result<ResolvedReviewTarget, String> {
    if let (Some(mode), Some(base_ref), Some(head_ref), Some(merge_base_sha)) =
        (mode, base_ref, head_ref, merge_base_sha)
    {
        return Ok(ResolvedReviewTarget {
            mode: review_mode_from_str(mode)?,
            base_ref: base_ref.to_string(),
            head_ref: head_ref.to_string(),
            merge_base_sha: merge_base_sha.to_string(),
        });
    }

    let repo_root = Path::new(repo_root);
    match mode {
        Some("branch") => resolve_branch_target(repo_root, base_ref, head_ref)
            .map_err(|error| format!("failed to resolve branch review target: {error}")),
        Some("uncommitted") => {
            if base_ref.is_some() || head_ref.is_some() {
                return Err(
                    "uncommitted review target cannot include base or head refs".to_string()
                );
            }
            resolve_uncommitted_target(repo_root)
                .map_err(|error| format!("failed to resolve uncommitted review target: {error}"))
        }
        Some(value) => Err(format!("invalid review mode: {value}")),
        None => auto_detect_review_target(repo_root)
            .map_err(|error| format!("failed to resolve review target: {error}")),
    }
}

fn store_from_repo_root(repo_root: *const c_char) -> Result<SessionStore, String> {
    Ok(SessionStore::for_repo_root(required_string(
        repo_root,
        "repo root",
    )?))
}

fn required_string(value: *const c_char, name: &str) -> Result<String, String> {
    string_from_c_pointer(value)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("{name} is required"))
}

fn optional_nonempty_string(value: *const c_char) -> Option<String> {
    string_from_c_pointer(value).filter(|value| !value.is_empty())
}

fn required_uuid(value: *const c_char, name: &str) -> Result<Uuid, String> {
    let value = required_string(value, name)?;
    Uuid::parse_str(&value).map_err(|error| format!("invalid {name}: {error}"))
}

fn optional_uuid(value: *const c_char, name: &str) -> Result<Option<Uuid>, String> {
    let Some(value) = optional_nonempty_string(value) else {
        return Ok(None);
    };
    Uuid::parse_str(&value)
        .map(Some)
        .map_err(|error| format!("invalid {name}: {error}"))
}

fn review_mode_from_str(value: &str) -> Result<ReviewMode, String> {
    match value {
        "branch" => Ok(ReviewMode::Branch),
        "uncommitted" => Ok(ReviewMode::Uncommitted),
        value => Err(format!("invalid review mode: {value}")),
    }
}

fn optional_outcome(value: *const c_char) -> Result<Option<ReviewOutcome>, String> {
    let Some(value) = optional_nonempty_string(value) else {
        return Ok(None);
    };
    match value.as_str() {
        "approved" => Ok(Some(ReviewOutcome::Approved)),
        "changes_requested" | "changes-requested" => Ok(Some(ReviewOutcome::ChangesRequested)),
        "commented" => Ok(Some(ReviewOutcome::Commented)),
        value => Err(format!("invalid review outcome: {value}")),
    }
}

fn comment_kind(input: &CommentInput) -> CommentKind {
    if !input.file_path.is_null() || input.line_new_present || input.line_old_present {
        CommentKind::Line
    } else {
        CommentKind::Global
    }
}

fn comment_anchor(input: &CommentInput) -> CommentAnchor {
    CommentAnchor {
        file_path: optional_nonempty_string(input.file_path),
        line_new: input.line_new_present.then_some(input.line_new),
        line_old: input.line_old_present.then_some(input.line_old),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn review_session_ffi_creates_and_updates_session() -> TestResult {
        let fixture = tempfile::tempdir()?;
        let repo_root = fixture.path().join("repo");
        std::fs::create_dir_all(&repo_root)?;
        let repo_root = repo_root.display().to_string();
        let repo_root_c = CString::new(repo_root.clone())?;
        let mode = CString::new("branch")?;
        let base_ref = CString::new("main")?;
        let head_ref = CString::new("feature")?;
        let merge_base_sha = CString::new("abc123")?;
        let change_summary = CString::new("Initial summary")?;

        let mut error = std::ptr::null_mut();
        let target = unsafe {
            argonlib_review_create_session(
                repo_root_c.as_ptr(),
                mode.as_ptr(),
                base_ref.as_ptr(),
                head_ref.as_ptr(),
                merge_base_sha.as_ptr(),
                change_summary.as_ptr(),
                &mut error,
            )
        };
        assert!(!target.is_null(), "unexpected error: {:?}", error);
        assert!(error.is_null());

        let session_id = unsafe { std::ffi::CStr::from_ptr((*target).session_id) }
            .to_string_lossy()
            .into_owned();
        let store = SessionStore::for_repo_root(&repo_root);
        let session_uuid = Uuid::parse_str(&session_id)?;
        let session = store.load(session_uuid)?;
        assert_eq!(session.mode, ReviewMode::Branch);
        assert_eq!(session.change_summary.as_deref(), Some("Initial summary"));

        let session_id = CString::new(session_id)?;
        let update_mode = CString::new("uncommitted")?;
        let update_base = CString::new("HEAD")?;
        let update_head = CString::new("WORKTREE")?;
        let update_merge_base = CString::new("def456")?;
        let updated = unsafe {
            argonlib_review_update_session_target(
                repo_root_c.as_ptr(),
                session_id.as_ptr(),
                update_mode.as_ptr(),
                update_base.as_ptr(),
                update_head.as_ptr(),
                update_merge_base.as_ptr(),
                &mut error,
            )
        };
        assert!(updated, "unexpected error: {:?}", error);

        let session = store.load(session_uuid)?;
        assert_eq!(session.mode, ReviewMode::Uncommitted);
        assert_eq!(session.base_ref, "HEAD");
        assert_eq!(session.head_ref, "WORKTREE");
        assert_eq!(session.merge_base_sha, "def456");

        unsafe {
            argonlib_review_target_free(target);
        }
        let _ = std::fs::remove_dir_all(store.sessions_dir());
        Ok(())
    }

    #[test]
    fn review_session_ffi_reports_invalid_session_id() {
        let repo_root = CString::new("/tmp").expect("repo root");
        let session_id = CString::new("not-a-uuid").expect("session id");
        let mut error = std::ptr::null_mut();

        let closed = unsafe {
            argonlib_review_close_session(repo_root.as_ptr(), session_id.as_ptr(), &mut error)
        };

        assert!(!closed);
        assert!(!error.is_null());
        unsafe {
            crate::argonlib_string_free(error);
        }
    }
}
