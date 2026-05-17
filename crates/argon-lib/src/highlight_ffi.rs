use std::os::raw::c_char;
use std::path::Path;

use argon_core::{
    DiffLineKind, HighlightedDiff, HighlightedFileDiff, HighlightedHunk, HighlightedLine,
    ReviewDiff, SessionStore, StyledSpan, build_review_diff, highlight_diff, highlight_text,
};
use uuid::Uuid;

use crate::{clear_error, owned_c_string, set_error, string_from_c_pointer};

const ARGON_DIFF_LINE_CONTEXT: u32 = 0;
const ARGON_DIFF_LINE_ADDED: u32 = 1;
const ARGON_DIFF_LINE_REMOVED: u32 = 2;
const DEFAULT_THEME: &str = "base16-ocean.dark";

#[repr(C)]
pub struct ArgonStyledSpan {
    pub text: *mut c_char,
    pub fg: *mut c_char,
    pub bold: bool,
    pub italic: bool,
    pub changed: bool,
}

#[repr(C)]
pub struct ArgonHighlightedLine {
    pub kind: u32,
    pub old_line_present: bool,
    pub old_line: u32,
    pub new_line_present: bool,
    pub new_line: u32,
    pub spans: *mut ArgonStyledSpan,
    pub span_count: usize,
}

#[repr(C)]
pub struct ArgonHighlightedText {
    pub lines: *mut ArgonHighlightedLine,
    pub line_count: usize,
}

#[repr(C)]
pub struct ArgonHighlightedHunk {
    pub header: *mut c_char,
    pub old_start: u32,
    pub old_line_count: u32,
    pub new_start: u32,
    pub new_line_count: u32,
    pub lines: *mut ArgonHighlightedLine,
    pub line_count: usize,
}

#[repr(C)]
pub struct ArgonSideBySidePair {
    pub left: *mut ArgonHighlightedLine,
    pub right: *mut ArgonHighlightedLine,
}

#[repr(C)]
pub struct ArgonHighlightedFile {
    pub old_path: *mut c_char,
    pub new_path: *mut c_char,
    pub unified_hunks: *mut ArgonHighlightedHunk,
    pub unified_hunk_count: usize,
    pub side_by_side: *mut ArgonSideBySidePair,
    pub side_by_side_count: usize,
    pub added_count: usize,
    pub removed_count: usize,
}

#[repr(C)]
pub struct ArgonHighlightedDiff {
    pub base_ref: *mut c_char,
    pub head_ref: *mut c_char,
    pub files: *mut ArgonHighlightedFile,
    pub file_count: usize,
}

/// Highlight arbitrary text and return owned C structs.
///
/// # Safety
///
/// `text`, `path`, and `theme` must be null or point to valid NUL-terminated C
/// strings. The returned pointer must be released with
/// `argonlib_highlighted_text_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_highlight_text(
    text: *const c_char,
    path: *const c_char,
    theme: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut ArgonHighlightedText {
    unsafe {
        clear_error(error_out);
    }

    let Some(text) = string_from_c_pointer(text) else {
        unsafe {
            set_error(error_out, "highlight text is required");
        }
        return std::ptr::null_mut();
    };
    let Some(path) = string_from_c_pointer(path) else {
        unsafe {
            set_error(error_out, "highlight path is required");
        }
        return std::ptr::null_mut();
    };
    let theme = string_from_c_pointer(theme)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_THEME.to_string());

    let highlighted = highlight_text(&text, &path, &theme);
    Box::into_raw(Box::new(ArgonHighlightedText::from_core(highlighted)))
}

/// Free a highlighted text response returned by `argonlib_highlight_text`.
///
/// # Safety
///
/// `value` must be null or a pointer returned by `argonlib_highlight_text`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_highlighted_text_free(value: *mut ArgonHighlightedText) {
    if value.is_null() {
        return;
    }

    let value = unsafe { Box::from_raw(value) };
    unsafe {
        free_line_array(value.lines, value.line_count);
    }
}

/// Load a review session, build its diff, highlight it, and return owned C structs.
///
/// # Safety
///
/// `repo_root`, `session_id`, and `theme` must be null or point to valid
/// NUL-terminated C strings. The returned pointer must be released with
/// `argonlib_highlighted_diff_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_highlight_diff_for_session(
    repo_root: *const c_char,
    session_id: *const c_char,
    theme: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut ArgonHighlightedDiff {
    unsafe {
        clear_error(error_out);
    }

    let Some(repo_root) = string_from_c_pointer(repo_root) else {
        unsafe {
            set_error(error_out, "repo root is required");
        }
        return std::ptr::null_mut();
    };
    let Some(session_id) = string_from_c_pointer(session_id) else {
        unsafe {
            set_error(error_out, "session id is required");
        }
        return std::ptr::null_mut();
    };
    let theme = string_from_c_pointer(theme)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_THEME.to_string());

    match highlighted_diff_for_session(&repo_root, &session_id, &theme) {
        Ok(diff) => Box::into_raw(Box::new(diff)),
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            std::ptr::null_mut()
        }
    }
}

/// Build and highlight a review diff for an explicit target.
///
/// # Safety
///
/// `repo_root`, `mode`, `base_ref`, `head_ref`, `merge_base_sha`, and `theme`
/// must be null or point to valid NUL-terminated C strings. The returned
/// pointer must be released with `argonlib_highlighted_diff_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_highlight_diff_for_target(
    repo_root: *const c_char,
    mode: *const c_char,
    base_ref: *const c_char,
    head_ref: *const c_char,
    merge_base_sha: *const c_char,
    theme: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut ArgonHighlightedDiff {
    unsafe {
        clear_error(error_out);
    }

    let theme = string_from_c_pointer(theme)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_THEME.to_string());

    match crate::diff_ffi::build_diff(repo_root, mode, base_ref, head_ref, merge_base_sha).map(
        |diff| {
            let highlighted = highlight_diff(&diff, &theme);
            ArgonHighlightedDiff::from_core(&diff, &highlighted)
        },
    ) {
        Ok(diff) => Box::into_raw(Box::new(diff)),
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            std::ptr::null_mut()
        }
    }
}

/// Free a highlighted diff response returned by `argonlib_highlight_diff_for_session`.
///
/// # Safety
///
/// `value` must be null or a pointer returned by
/// `argonlib_highlight_diff_for_session`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_highlighted_diff_free(value: *mut ArgonHighlightedDiff) {
    if value.is_null() {
        return;
    }

    let value = unsafe { Box::from_raw(value) };
    unsafe {
        crate::argonlib_string_free(value.base_ref);
        crate::argonlib_string_free(value.head_ref);
        free_file_array(value.files, value.file_count);
    }
}

fn highlighted_diff_for_session(
    repo_root: &str,
    session_id: &str,
    theme: &str,
) -> Result<ArgonHighlightedDiff, String> {
    let session_id =
        Uuid::parse_str(session_id).map_err(|error| format!("invalid session id: {error}"))?;
    let store = SessionStore::for_repo_root(repo_root);
    let session = store
        .load(session_id)
        .map_err(|error| format!("failed to load session: {error}"))?;
    let diff = build_review_diff(
        Path::new(&session.repo_root),
        session.mode,
        &session.base_ref,
        &session.head_ref,
        &session.merge_base_sha,
    )
    .map_err(|error| format!("failed to build diff: {error}"))?;
    let highlighted = highlight_diff(&diff, theme);
    Ok(ArgonHighlightedDiff::from_core(&diff, &highlighted))
}

impl ArgonStyledSpan {
    fn from_core(span: &StyledSpan) -> Self {
        Self {
            text: owned_c_string(span.text.clone()),
            fg: span
                .fg
                .as_ref()
                .map(|color| owned_c_string(color.clone()))
                .unwrap_or(std::ptr::null_mut()),
            bold: span.bold,
            italic: span.italic,
            changed: span.changed,
        }
    }
}

impl ArgonHighlightedLine {
    fn from_core(line: &HighlightedLine) -> Self {
        let (spans, span_count) =
            into_raw_array(line.spans.iter().map(ArgonStyledSpan::from_core).collect());
        Self {
            kind: diff_line_kind(line.kind),
            old_line_present: line.old_line.is_some(),
            old_line: line.old_line.unwrap_or_default(),
            new_line_present: line.new_line.is_some(),
            new_line: line.new_line.unwrap_or_default(),
            spans,
            span_count,
        }
    }
}

impl ArgonHighlightedText {
    fn from_core(lines: Vec<Vec<StyledSpan>>) -> Self {
        let (lines, line_count) = into_raw_array(
            lines
                .into_iter()
                .map(|spans| {
                    let line = HighlightedLine {
                        kind: DiffLineKind::Context,
                        old_line: None,
                        new_line: None,
                        spans,
                    };
                    ArgonHighlightedLine::from_core(&line)
                })
                .collect(),
        );
        Self { lines, line_count }
    }
}

impl ArgonHighlightedHunk {
    fn from_core(hunk: &HighlightedHunk, source: Option<&argon_core::DiffHunk>) -> Self {
        let (lines, line_count) = into_raw_array(
            hunk.lines
                .iter()
                .map(ArgonHighlightedLine::from_core)
                .collect(),
        );
        Self {
            header: owned_c_string(hunk.header.clone()),
            old_start: source.map(|hunk| hunk.old_start).unwrap_or_default(),
            old_line_count: source.map(|hunk| hunk.old_lines).unwrap_or_default(),
            new_start: source.map(|hunk| hunk.new_start).unwrap_or_default(),
            new_line_count: source.map(|hunk| hunk.new_lines).unwrap_or_default(),
            lines,
            line_count,
        }
    }
}

impl ArgonSideBySidePair {
    fn from_core(pair: &argon_core::SideBySidePair) -> Self {
        Self {
            left: optional_line_pointer(pair.left.as_ref()),
            right: optional_line_pointer(pair.right.as_ref()),
        }
    }
}

impl ArgonHighlightedFile {
    fn from_core(source: Option<&argon_core::FileDiff>, file: &HighlightedFileDiff) -> Self {
        let (unified_hunks, unified_hunk_count) = into_raw_array(
            file.unified_hunks
                .iter()
                .enumerate()
                .map(|(index, hunk)| {
                    ArgonHighlightedHunk::from_core(
                        hunk,
                        source.and_then(|file| file.hunks.get(index)),
                    )
                })
                .collect(),
        );
        let (side_by_side, side_by_side_count) = into_raw_array(
            file.side_by_side
                .iter()
                .map(ArgonSideBySidePair::from_core)
                .collect(),
        );
        Self {
            old_path: owned_c_string(file.old_path.clone()),
            new_path: owned_c_string(file.new_path.clone()),
            unified_hunks,
            unified_hunk_count,
            side_by_side,
            side_by_side_count,
            added_count: file.added_count,
            removed_count: file.removed_count,
        }
    }
}

impl ArgonHighlightedDiff {
    fn from_core(source: &ReviewDiff, diff: &HighlightedDiff) -> Self {
        let (files, file_count) = into_raw_array(
            diff.files
                .iter()
                .enumerate()
                .map(|(index, file)| ArgonHighlightedFile::from_core(source.files.get(index), file))
                .collect(),
        );
        Self {
            base_ref: owned_c_string(diff.base_ref.clone()),
            head_ref: owned_c_string(diff.head_ref.clone()),
            files,
            file_count,
        }
    }
}

fn diff_line_kind(kind: DiffLineKind) -> u32 {
    match kind {
        DiffLineKind::Context => ARGON_DIFF_LINE_CONTEXT,
        DiffLineKind::Added => ARGON_DIFF_LINE_ADDED,
        DiffLineKind::Removed => ARGON_DIFF_LINE_REMOVED,
    }
}

fn optional_line_pointer(line: Option<&HighlightedLine>) -> *mut ArgonHighlightedLine {
    line.map(|line| Box::into_raw(Box::new(ArgonHighlightedLine::from_core(line))))
        .unwrap_or(std::ptr::null_mut())
}

fn into_raw_array<T>(values: Vec<T>) -> (*mut T, usize) {
    if values.is_empty() {
        return (std::ptr::null_mut(), 0);
    }

    let mut values = values.into_boxed_slice();
    let count = values.len();
    let pointer = values.as_mut_ptr();
    std::mem::forget(values);
    (pointer, count)
}

unsafe fn free_span_array(pointer: *mut ArgonStyledSpan, count: usize) {
    unsafe {
        free_raw_array(pointer, count, |span| {
            crate::argonlib_string_free(span.text);
            crate::argonlib_string_free(span.fg);
        });
    }
}

unsafe fn free_line_contents(line: &mut ArgonHighlightedLine) {
    unsafe {
        free_span_array(line.spans, line.span_count);
    }
}

unsafe fn free_line_pointer(pointer: *mut ArgonHighlightedLine) {
    if pointer.is_null() {
        return;
    }
    let mut line = unsafe { Box::from_raw(pointer) };
    unsafe {
        free_line_contents(&mut line);
    }
}

unsafe fn free_line_array(pointer: *mut ArgonHighlightedLine, count: usize) {
    unsafe {
        free_raw_array(pointer, count, |line| {
            free_line_contents(line);
        });
    }
}

unsafe fn free_hunk_array(pointer: *mut ArgonHighlightedHunk, count: usize) {
    unsafe {
        free_raw_array(pointer, count, |hunk| {
            crate::argonlib_string_free(hunk.header);
            free_line_array(hunk.lines, hunk.line_count);
        });
    }
}

unsafe fn free_side_by_side_array(pointer: *mut ArgonSideBySidePair, count: usize) {
    unsafe {
        free_raw_array(pointer, count, |pair| {
            free_line_pointer(pair.left);
            free_line_pointer(pair.right);
        });
    }
}

unsafe fn free_file_array(pointer: *mut ArgonHighlightedFile, count: usize) {
    unsafe {
        free_raw_array(pointer, count, |file| {
            crate::argonlib_string_free(file.old_path);
            crate::argonlib_string_free(file.new_path);
            free_hunk_array(file.unified_hunks, file.unified_hunk_count);
            free_side_by_side_array(file.side_by_side, file.side_by_side_count);
        });
    }
}

unsafe fn free_raw_array<T>(pointer: *mut T, count: usize, mut free_item: impl FnMut(&mut T)) {
    if pointer.is_null() || count == 0 {
        return;
    }

    let slice = unsafe { std::slice::from_raw_parts_mut(pointer, count) };
    for item in slice {
        free_item(item);
    }

    let slice_pointer = std::ptr::slice_from_raw_parts_mut(pointer, count);
    let _ = unsafe { Box::from_raw(slice_pointer) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::fs;
    use std::process::Command;
    use std::sync::Mutex;

    use argon_core::ReviewMode;
    use tempfile::TempDir;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn highlight_text_returns_lines_and_spans() {
        let text = CString::new("let value = 1\n").expect("text cstring");
        let path = CString::new("src/lib.rs").expect("path cstring");
        let theme = CString::new(DEFAULT_THEME).expect("theme cstring");
        let mut error = std::ptr::null_mut();

        let response = unsafe {
            argonlib_highlight_text(text.as_ptr(), path.as_ptr(), theme.as_ptr(), &mut error)
        };

        assert!(error.is_null());
        assert!(!response.is_null());
        let response_ref = unsafe { &*response };
        assert_eq!(response_ref.line_count, 2);

        let first_line = unsafe { &*response_ref.lines };
        assert!(first_line.span_count > 0);
        let first_span = unsafe { &*first_line.spans };
        assert!(!first_span.text.is_null());

        unsafe {
            argonlib_highlighted_text_free(response);
        }
    }

    #[test]
    fn highlight_diff_for_session_returns_file_hunks() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let repo = setup_git_repo();
        let storage = tempfile::tempdir().expect("storage");
        let previous_argon_home = std::env::var_os("ARGON_HOME");
        unsafe {
            std::env::set_var("ARGON_HOME", storage.path());
        }

        let head = git(&repo, &["rev-parse", "HEAD"]);
        let store = SessionStore::for_repo_root_with_storage_root(repo.path(), storage.path());
        let session = store
            .create_session_with_mode(ReviewMode::Uncommitted, &head, "WORKTREE", &head)
            .expect("create session");
        fs::write(
            repo.path().join("src/lib.rs"),
            "pub fn value() -> i32 {\n    2\n}\n",
        )
        .expect("modify file");

        let repo_root = CString::new(repo.path().to_string_lossy().as_ref()).expect("repo root");
        let session_id = CString::new(session.id.to_string()).expect("session id");
        let theme = CString::new(DEFAULT_THEME).expect("theme");
        let mut error = std::ptr::null_mut();

        let response = unsafe {
            argonlib_highlight_diff_for_session(
                repo_root.as_ptr(),
                session_id.as_ptr(),
                theme.as_ptr(),
                &mut error,
            )
        };

        restore_env("ARGON_HOME", previous_argon_home);

        assert!(error.is_null());
        assert!(!response.is_null());
        let response_ref = unsafe { &*response };
        assert_eq!(response_ref.file_count, 1);
        let file = unsafe { &*response_ref.files };
        assert_eq!(
            unsafe { std::ffi::CStr::from_ptr(file.new_path) }.to_str(),
            Ok("src/lib.rs")
        );
        assert_eq!(file.added_count, 1);
        assert_eq!(file.removed_count, 1);
        assert!(file.unified_hunk_count > 0);
        assert!(file.side_by_side_count > 0);

        unsafe {
            argonlib_highlighted_diff_free(response);
        }
    }

    #[test]
    fn highlight_diff_for_session_reports_invalid_session_id() {
        let repo_root = CString::new("/tmp").expect("repo root");
        let session_id = CString::new("not-a-uuid").expect("session id");
        let theme = CString::new(DEFAULT_THEME).expect("theme");
        let mut error = std::ptr::null_mut();

        let response = unsafe {
            argonlib_highlight_diff_for_session(
                repo_root.as_ptr(),
                session_id.as_ptr(),
                theme.as_ptr(),
                &mut error,
            )
        };

        assert!(response.is_null());
        assert!(!error.is_null());
        let message = unsafe { std::ffi::CStr::from_ptr(error) }.to_string_lossy();
        assert!(message.contains("invalid session id"));
        unsafe {
            crate::argonlib_string_free(error);
        }
    }

    fn setup_git_repo() -> TempDir {
        let repo = tempfile::tempdir().expect("repo");
        git(&repo, &["init"]);
        git(&repo, &["config", "user.email", "test@example.com"]);
        git(&repo, &["config", "user.name", "Test User"]);
        fs::create_dir_all(repo.path().join("src")).expect("create src");
        fs::write(
            repo.path().join("src/lib.rs"),
            "pub fn value() -> i32 {\n    1\n}\n",
        )
        .expect("write file");
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-m", "initial"]);
        repo
    }

    fn git(repo: &TempDir, args: &[&str]) -> String {
        let output = Command::new("git")
            .current_dir(repo.path())
            .args(args)
            .output()
            .expect("run git");
        assert!(
            output.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    fn restore_env(name: &str, value: Option<std::ffi::OsString>) {
        unsafe {
            match value {
                Some(value) => std::env::set_var(name, value),
                None => std::env::remove_var(name),
            }
        }
    }
}
