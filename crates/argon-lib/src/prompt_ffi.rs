use std::os::raw::c_char;

use argon_core::{
    SessionStore, build_agent_prompt, build_reviewer_prompt, latest_reviewer_feedback_seen_at,
    normalize_reviewer_name,
};
use uuid::Uuid;

use crate::{clear_error, owned_c_string, set_error, string_from_c_pointer};

/// Build an agent handoff prompt for a review session without shelling out.
///
/// # Safety
///
/// All string pointers must point to valid NUL-terminated C strings. The
/// returned pointer must be released with `argonlib_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_agent_prompt(
    repo_root: *const c_char,
    session_id: *const c_char,
    cli_command: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    unsafe {
        clear_error(error_out);
    }

    match agent_prompt(repo_root, session_id, cli_command) {
        Ok(prompt) => owned_c_string(prompt),
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            std::ptr::null_mut()
        }
    }
}

/// Build a reviewer handoff prompt for a review session without shelling out.
///
/// # Safety
///
/// All string pointers must be null or point to valid NUL-terminated C strings,
/// except `repo_root`, `session_id`, and `cli_command`, which are required. The
/// returned pointer must be released with `argonlib_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_reviewer_prompt(
    repo_root: *const c_char,
    session_id: *const c_char,
    reviewer_name: *const c_char,
    cli_command: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    unsafe {
        clear_error(error_out);
    }

    match reviewer_prompt(repo_root, session_id, reviewer_name, cli_command) {
        Ok(prompt) => owned_c_string(prompt),
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            std::ptr::null_mut()
        }
    }
}

fn agent_prompt(
    repo_root: *const c_char,
    session_id: *const c_char,
    cli_command: *const c_char,
) -> Result<String, String> {
    let store = store_from_repo_root(repo_root)?;
    let session_id = required_uuid(session_id, "session id")?;
    let cli_command = required_string(cli_command, "cli command")?;
    let session = store
        .load(session_id)
        .map_err(|error| format!("failed to load review session: {error}"))?;
    Ok(build_agent_prompt(&session, &cli_command).prompt)
}

fn reviewer_prompt(
    repo_root: *const c_char,
    session_id: *const c_char,
    reviewer_name: *const c_char,
    cli_command: *const c_char,
) -> Result<String, String> {
    let store = store_from_repo_root(repo_root)?;
    let session_id = required_uuid(session_id, "session id")?;
    let reviewer_name = normalize_reviewer_name(optional_nonempty_string(reviewer_name).as_deref());
    let cli_command = required_string(cli_command, "cli command")?;
    let session = store
        .load(session_id)
        .map_err(|error| format!("failed to load review session: {error}"))?;
    let last_seen_at = store
        .load_reviewer_last_seen(session_id, &reviewer_name)
        .map_err(|error| format!("failed to load reviewer state: {error}"))?;
    let prompt = build_reviewer_prompt(&session, &reviewer_name, last_seen_at, &cli_command);
    if let Some(last_seen_at) = latest_reviewer_feedback_seen_at(&prompt.pending_feedback) {
        store
            .mark_reviewer_seen(session_id, &prompt.reviewer_name, Some(last_seen_at))
            .map_err(|error| format!("failed to mark reviewer feedback seen: {error}"))?;
    }
    Ok(prompt.prompt)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn agent_prompt_ffi_returns_handoff_prompt() -> TestResult {
        let fixture = tempfile::tempdir()?;
        let repo_root = fixture.path().join("repo");
        std::fs::create_dir_all(&repo_root)?;
        let repo_root = repo_root.display().to_string();
        let store = SessionStore::for_repo_root(&repo_root);
        let session = store.create_session("main", "feature", "abc123")?;

        let repo_root_c = CString::new(repo_root)?;
        let session_id = CString::new(session.id.to_string())?;
        let cli_command = CString::new("argon")?;
        let mut error = std::ptr::null_mut();
        let prompt = unsafe {
            argonlib_agent_prompt(
                repo_root_c.as_ptr(),
                session_id.as_ptr(),
                cli_command.as_ptr(),
                &mut error,
            )
        };

        assert!(error.is_null());
        assert!(!prompt.is_null());
        let prompt_text = unsafe { std::ffi::CStr::from_ptr(prompt) }.to_string_lossy();
        assert!(prompt_text.contains("Execution contract:"));
        assert!(prompt_text.contains("agent wait --session"));
        unsafe {
            crate::argonlib_string_free(prompt);
        }
        Ok(())
    }
}
