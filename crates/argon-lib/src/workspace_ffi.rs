use std::os::raw::c_char;
use std::path::Path;

use argon_core::{MergeabilityStatus, WorktreeMergeability, inspect_worktree_mergeability};

use crate::{clear_error, owned_c_string, set_error, string_from_c_pointer};

const ARGON_MERGEABILITY_STATUS_UNKNOWN: u32 = 0;
const ARGON_MERGEABILITY_STATUS_CLEAN: u32 = 1;
const ARGON_MERGEABILITY_STATUS_CONFLICTED: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ArgonWorkspaceBranchTopology {
    pub ahead_count: u32,
    pub behind_count: u32,
}

#[repr(C)]
pub struct ArgonWorkspaceMergeability {
    pub status: u32,
    pub base_ref: *mut c_char,
    pub head_ref: *mut c_char,
    pub merge_base_sha: *mut c_char,
    pub topology_present: bool,
    pub topology: ArgonWorkspaceBranchTopology,
    pub detail: *mut c_char,
}

/// Inspect whether a worktree branch can merge into its base without conflicts.
///
/// # Safety
///
/// `repo_root`, `base_ref`, and `head_ref` must be null or point to valid
/// NUL-terminated C strings. The returned pointer must be released with
/// `argonlib_workspace_mergeability_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_workspace_mergeability(
    repo_root: *const c_char,
    base_ref: *const c_char,
    head_ref: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut ArgonWorkspaceMergeability {
    unsafe {
        clear_error(error_out);
    }

    match workspace_mergeability(repo_root, base_ref, head_ref) {
        Ok(mergeability) => Box::into_raw(Box::new(ArgonWorkspaceMergeability::from_core(
            &mergeability,
        ))),
        Err(error) => {
            unsafe {
                set_error(error_out, error);
            }
            std::ptr::null_mut()
        }
    }
}

/// Free a mergeability response returned by `argonlib_workspace_mergeability`.
///
/// # Safety
///
/// `value` must be null or a pointer returned by
/// `argonlib_workspace_mergeability`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn argonlib_workspace_mergeability_free(
    value: *mut ArgonWorkspaceMergeability,
) {
    if value.is_null() {
        return;
    }

    let value = unsafe { Box::from_raw(value) };
    unsafe {
        crate::argonlib_string_free(value.base_ref);
        crate::argonlib_string_free(value.head_ref);
        crate::argonlib_string_free(value.merge_base_sha);
        crate::argonlib_string_free(value.detail);
    }
}

fn workspace_mergeability(
    repo_root: *const c_char,
    base_ref: *const c_char,
    head_ref: *const c_char,
) -> Result<WorktreeMergeability, String> {
    let repo_root =
        string_from_c_pointer(repo_root).ok_or_else(|| "repo root is required".to_string())?;
    let base_ref = optional_nonempty_string_from_c_pointer(base_ref);
    let head_ref = optional_nonempty_string_from_c_pointer(head_ref);

    Ok(inspect_worktree_mergeability(
        Path::new(&repo_root),
        base_ref.as_deref(),
        head_ref.as_deref(),
    ))
}

fn optional_nonempty_string_from_c_pointer(value: *const c_char) -> Option<String> {
    string_from_c_pointer(value).filter(|value| !value.is_empty())
}

impl ArgonWorkspaceMergeability {
    fn from_core(mergeability: &WorktreeMergeability) -> Self {
        let topology = mergeability
            .topology
            .as_ref()
            .map(|topology| ArgonWorkspaceBranchTopology {
                ahead_count: topology.ahead_count,
                behind_count: topology.behind_count,
            })
            .unwrap_or(ArgonWorkspaceBranchTopology {
                ahead_count: 0,
                behind_count: 0,
            });

        Self {
            status: mergeability_status(mergeability.status),
            base_ref: optional_c_string(mergeability.base_ref.as_deref()),
            head_ref: optional_c_string(mergeability.head_ref.as_deref()),
            merge_base_sha: optional_c_string(mergeability.merge_base_sha.as_deref()),
            topology_present: mergeability.topology.is_some(),
            topology,
            detail: optional_c_string(mergeability.detail.as_deref()),
        }
    }
}

fn mergeability_status(status: MergeabilityStatus) -> u32 {
    match status {
        MergeabilityStatus::Unknown => ARGON_MERGEABILITY_STATUS_UNKNOWN,
        MergeabilityStatus::Clean => ARGON_MERGEABILITY_STATUS_CLEAN,
        MergeabilityStatus::Conflicted => ARGON_MERGEABILITY_STATUS_CONFLICTED,
    }
}

fn optional_c_string(value: Option<&str>) -> *mut c_char {
    value
        .map(|value| owned_c_string(value.to_string()))
        .unwrap_or(std::ptr::null_mut())
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::ffi::{CStr, CString};
    use std::fs;
    use std::process::Command;

    use tempfile::TempDir;

    use super::*;

    type TestResult<T = ()> = Result<T, Box<dyn Error>>;

    #[test]
    fn workspace_mergeability_returns_branch_topology() -> TestResult {
        let (_fixture, worktree) = setup_repo_with_feature_worktree()?;
        fs::write(worktree.path().join("feature.txt"), "feature\n")?;
        git(worktree.path(), &["add", "feature.txt"])?;
        git(worktree.path(), &["commit", "-m", "feature"])?;

        let repo_root = CString::new(worktree.path().display().to_string())?;
        let mut error = std::ptr::null_mut();
        let response = unsafe {
            argonlib_workspace_mergeability(
                repo_root.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                &mut error,
            )
        };

        assert!(error.is_null());
        assert!(!response.is_null());
        let response_ref = unsafe { &*response };
        assert_eq!(response_ref.status, ARGON_MERGEABILITY_STATUS_CLEAN);
        assert!(response_ref.topology_present);
        assert_eq!(response_ref.topology.ahead_count, 1);
        assert_eq!(
            unsafe { CStr::from_ptr(response_ref.base_ref) }.to_str(),
            Ok("main")
        );

        unsafe {
            argonlib_workspace_mergeability_free(response);
        }
        Ok(())
    }

    #[test]
    fn workspace_mergeability_requires_repo_root() {
        let mut error = std::ptr::null_mut();
        let response = unsafe {
            argonlib_workspace_mergeability(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                &mut error,
            )
        };

        assert!(response.is_null());
        assert!(!error.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(error) }.to_str(),
            Ok("repo root is required")
        );
        unsafe {
            crate::argonlib_string_free(error);
        }
    }

    fn setup_repo_with_feature_worktree() -> TestResult<(TempDir, TempDir)> {
        let fixture = TempDir::new()?;
        let repo = fixture.path().join("repo");
        fs::create_dir_all(&repo)?;

        git(&repo, &["init"])?;
        git(&repo, &["config", "user.name", "Argon Test"])?;
        git(&repo, &["config", "user.email", "argon-test@example.com"])?;
        fs::write(repo.join("README.md"), "base\n")?;
        git(&repo, &["add", "README.md"])?;
        git(&repo, &["commit", "-m", "init"])?;
        git(&repo, &["branch", "-M", "main"])?;

        let worktree = TempDir::new()?;
        fs::remove_dir(worktree.path())?;
        git(
            &repo,
            &[
                "worktree",
                "add",
                "-b",
                "feature/topic",
                worktree.path().to_str().unwrap(),
                "HEAD",
            ],
        )?;

        Ok((fixture, worktree))
    }

    fn git(repo: &Path, args: &[&str]) -> TestResult<String> {
        let output = Command::new("git").current_dir(repo).args(args).output()?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(format!("git {} failed: {stderr}", args.join(" ")).into());
        }

        let stdout = String::from_utf8(output.stdout)?;
        Ok(stdout.trim().to_string())
    }
}
