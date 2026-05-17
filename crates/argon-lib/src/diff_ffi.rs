use std::os::raw::c_char;
use std::path::Path;

use argon_core::{DiffLineKind, FileDiff, ReviewDiff, build_review_diff, diff_fingerprint};

use crate::{
    clear_error, owned_c_string, review_mode_from_c_pointer, set_error, string_from_c_pointer,
};

const ARGON_DIFF_LINE_CONTEXT: u32 = 0;
const ARGON_DIFF_LINE_ADDED: u32 = 1;
const ARGON_DIFF_LINE_REMOVED: u32 = 2;

#[repr(C)]
pub struct ArgonDiffLine {
    pub kind: u32,
    pub old_line_present: bool,
    pub old_line: u32,
    pub new_line_present: bool,
    pub new_line: u32,
    pub content: *mut c_char,
}

#[repr(C)]
pub struct ArgonDiffHunk {
    pub header: *mut c_char,
    pub old_start: u32,
    pub old_line_count: u32,
    pub new_start: u32,
    pub new_line_count: u32,
    pub lines: *mut ArgonDiffLine,
    pub line_count: usize,
}

#[repr(C)]
pub struct ArgonDiffFile {
    pub old_path: *mut c_char,
    pub new_path: *mut c_char,
    pub hunks: *mut ArgonDiffHunk,
    pub hunk_count: usize,
    pub added_count: usize,
    pub removed_count: usize,
}

#[repr(C)]
pub struct ArgonDiff {
    pub base_ref: *mut c_char,
    pub head_ref: *mut c_char,
    pub merge_base_sha: *mut c_char,
    pub files: *mut ArgonDiffFile,
    pub file_count: usize,
}

/// Build a review diff and return owned C structs.
///
/// # Safety
///
/// `repo_root`, `mode`, `base_ref`, `head_ref`, and `merge_base_sha` must be
/// null or point to valid NUL-terminated C strings. The returned pointer must
/// be released with `argonlib_diff_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_build_diff(
    repo_root: *const c_char,
    mode: *const c_char,
    base_ref: *const c_char,
    head_ref: *const c_char,
    merge_base_sha: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut ArgonDiff {
    unsafe {
        clear_error(error_out);
    }

    match build_diff(repo_root, mode, base_ref, head_ref, merge_base_sha) {
        Ok(diff) => Box::into_raw(Box::new(ArgonDiff::from_core(&diff))),
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            std::ptr::null_mut()
        }
    }
}

/// Free a diff response returned by `argonlib_build_diff`.
///
/// # Safety
///
/// `value` must be null or a pointer returned by `argonlib_build_diff`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_diff_free(value: *mut ArgonDiff) {
    if value.is_null() {
        return;
    }

    let value = unsafe { Box::from_raw(value) };
    unsafe {
        crate::argonlib_string_free(value.base_ref);
        crate::argonlib_string_free(value.head_ref);
        crate::argonlib_string_free(value.merge_base_sha);
        free_file_array(value.files, value.file_count);
    }
}

/// Build a lightweight diff fingerprint for change detection.
///
/// # Safety
///
/// `repo_root`, `mode`, `head_ref`, and `merge_base_sha` must be null or
/// point to valid NUL-terminated C strings. The returned pointer must be
/// released with `argonlib_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_diff_fingerprint(
    repo_root: *const c_char,
    mode: *const c_char,
    head_ref: *const c_char,
    merge_base_sha: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    unsafe {
        clear_error(error_out);
    }

    match build_diff_fingerprint(repo_root, mode, head_ref, merge_base_sha) {
        Ok(value) => owned_c_string(value),
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            std::ptr::null_mut()
        }
    }
}

pub(crate) fn build_diff(
    repo_root: *const c_char,
    mode: *const c_char,
    base_ref: *const c_char,
    head_ref: *const c_char,
    merge_base_sha: *const c_char,
) -> Result<ReviewDiff, String> {
    let repo_root =
        string_from_c_pointer(repo_root).ok_or_else(|| "repo root is required".to_string())?;
    let mode = review_mode_from_c_pointer(mode)?;
    let base_ref =
        string_from_c_pointer(base_ref).ok_or_else(|| "base ref is required".to_string())?;
    let head_ref =
        string_from_c_pointer(head_ref).ok_or_else(|| "head ref is required".to_string())?;
    let merge_base_sha = string_from_c_pointer(merge_base_sha)
        .ok_or_else(|| "merge base sha is required".to_string())?;

    let repo_root = Path::new(&repo_root);
    if !repo_root.is_dir() {
        return Ok(empty_diff(base_ref, head_ref, merge_base_sha));
    }

    build_review_diff(repo_root, mode, &base_ref, &head_ref, &merge_base_sha)
        .map_err(|error| format!("failed to build diff: {error}"))
}

fn build_diff_fingerprint(
    repo_root: *const c_char,
    mode: *const c_char,
    head_ref: *const c_char,
    merge_base_sha: *const c_char,
) -> Result<String, String> {
    let repo_root =
        string_from_c_pointer(repo_root).ok_or_else(|| "repo root is required".to_string())?;
    let mode = review_mode_from_c_pointer(mode)?;
    let head_ref =
        string_from_c_pointer(head_ref).ok_or_else(|| "head ref is required".to_string())?;
    let merge_base_sha = string_from_c_pointer(merge_base_sha)
        .ok_or_else(|| "merge base sha is required".to_string())?;

    let repo_root = Path::new(&repo_root);
    if !repo_root.is_dir() {
        return Ok(String::new());
    }

    diff_fingerprint(repo_root, mode, &head_ref, &merge_base_sha)
        .map_err(|error| format!("failed to build diff fingerprint: {error}"))
}

fn empty_diff(base_ref: String, head_ref: String, merge_base_sha: String) -> ReviewDiff {
    ReviewDiff {
        base_ref,
        head_ref,
        merge_base_sha,
        files: Vec::new(),
    }
}

impl ArgonDiffLine {
    fn from_core(line: &argon_core::DiffLine) -> Self {
        Self {
            kind: diff_line_kind(line.kind),
            old_line_present: line.old_line.is_some(),
            old_line: line.old_line.unwrap_or_default(),
            new_line_present: line.new_line.is_some(),
            new_line: line.new_line.unwrap_or_default(),
            content: owned_c_string(line.content.clone()),
        }
    }
}

impl ArgonDiffHunk {
    fn from_core(hunk: &argon_core::DiffHunk) -> Self {
        let (lines, line_count) =
            into_raw_array(hunk.lines.iter().map(ArgonDiffLine::from_core).collect());
        Self {
            header: owned_c_string(hunk.header.clone()),
            old_start: hunk.old_start,
            old_line_count: hunk.old_lines,
            new_start: hunk.new_start,
            new_line_count: hunk.new_lines,
            lines,
            line_count,
        }
    }
}

impl ArgonDiffFile {
    fn from_core(file: &FileDiff) -> Self {
        let (hunks, hunk_count) =
            into_raw_array(file.hunks.iter().map(ArgonDiffHunk::from_core).collect());
        let added_count = file
            .hunks
            .iter()
            .flat_map(|hunk| &hunk.lines)
            .filter(|line| line.kind == DiffLineKind::Added)
            .count();
        let removed_count = file
            .hunks
            .iter()
            .flat_map(|hunk| &hunk.lines)
            .filter(|line| line.kind == DiffLineKind::Removed)
            .count();

        Self {
            old_path: owned_c_string(file.old_path.clone()),
            new_path: owned_c_string(file.new_path.clone()),
            hunks,
            hunk_count,
            added_count,
            removed_count,
        }
    }
}

impl ArgonDiff {
    fn from_core(diff: &ReviewDiff) -> Self {
        let (files, file_count) =
            into_raw_array(diff.files.iter().map(ArgonDiffFile::from_core).collect());
        Self {
            base_ref: owned_c_string(diff.base_ref.clone()),
            head_ref: owned_c_string(diff.head_ref.clone()),
            merge_base_sha: owned_c_string(diff.merge_base_sha.clone()),
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

fn into_raw_array<T>(mut values: Vec<T>) -> (*mut T, usize) {
    if values.is_empty() {
        return (std::ptr::null_mut(), 0);
    }
    values.shrink_to_fit();
    let count = values.len();
    let pointer = values.as_mut_ptr();
    std::mem::forget(values);
    (pointer, count)
}

unsafe fn free_file_array(pointer: *mut ArgonDiffFile, count: usize) {
    if pointer.is_null() {
        return;
    }

    let values = unsafe { Vec::from_raw_parts(pointer, count, count) };
    for file in values {
        unsafe {
            crate::argonlib_string_free(file.old_path);
            crate::argonlib_string_free(file.new_path);
            free_hunk_array(file.hunks, file.hunk_count);
        }
    }
}

unsafe fn free_hunk_array(pointer: *mut ArgonDiffHunk, count: usize) {
    if pointer.is_null() {
        return;
    }

    let values = unsafe { Vec::from_raw_parts(pointer, count, count) };
    for hunk in values {
        unsafe {
            crate::argonlib_string_free(hunk.header);
            free_line_array(hunk.lines, hunk.line_count);
        }
    }
}

unsafe fn free_line_array(pointer: *mut ArgonDiffLine, count: usize) {
    if pointer.is_null() {
        return;
    }

    let values = unsafe { Vec::from_raw_parts(pointer, count, count) };
    for line in values {
        unsafe {
            crate::argonlib_string_free(line.content);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};
    use std::fs;

    #[test]
    fn build_diff_returns_empty_for_missing_repo_root() {
        let repo_root = missing_repo_root("build-diff");
        let repo_root = CString::new(repo_root.to_str().expect("utf8 temp path")).unwrap();
        let mode = CString::new("uncommitted").unwrap();
        let base_ref = CString::new("HEAD").unwrap();
        let head_ref = CString::new("WORKTREE").unwrap();
        let merge_base_sha = CString::new("HEAD").unwrap();
        let mut error = std::ptr::null_mut();

        let response = unsafe {
            argonlib_build_diff(
                repo_root.as_ptr(),
                mode.as_ptr(),
                base_ref.as_ptr(),
                head_ref.as_ptr(),
                merge_base_sha.as_ptr(),
                &mut error,
            )
        };

        assert!(error.is_null());
        assert!(!response.is_null());
        let response_ref = unsafe { &*response };
        assert_eq!(response_ref.file_count, 0);
        assert!(response_ref.files.is_null());
        unsafe {
            argonlib_diff_free(response);
        }
    }

    #[test]
    fn diff_fingerprint_returns_empty_for_missing_repo_root() {
        let repo_root = missing_repo_root("fingerprint");
        let repo_root = CString::new(repo_root.to_str().expect("utf8 temp path")).unwrap();
        let mode = CString::new("uncommitted").unwrap();
        let head_ref = CString::new("WORKTREE").unwrap();
        let merge_base_sha = CString::new("HEAD").unwrap();
        let mut error = std::ptr::null_mut();

        let response = unsafe {
            argonlib_diff_fingerprint(
                repo_root.as_ptr(),
                mode.as_ptr(),
                head_ref.as_ptr(),
                merge_base_sha.as_ptr(),
                &mut error,
            )
        };

        assert!(error.is_null());
        assert!(!response.is_null());
        assert_eq!(unsafe { CStr::from_ptr(response) }.to_str(), Ok(""));
        unsafe {
            crate::argonlib_string_free(response);
        }
    }

    fn missing_repo_root(name: &str) -> std::path::PathBuf {
        let path =
            std::env::temp_dir().join(format!("argon-lib-missing-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        path
    }
}
