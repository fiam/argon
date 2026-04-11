use std::io;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::model::CommentAnchor;
use crate::model::ReviewMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiffLineKind {
    Context,
    Added,
    Removed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffLine {
    pub kind: DiffLineKind,
    pub content: String,
    pub old_line: Option<u32>,
    pub new_line: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffHunk {
    pub header: String,
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    pub lines: Vec<DiffLine>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileDiff {
    pub old_path: String,
    pub new_path: String,
    pub hunks: Vec<DiffHunk>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewDiff {
    pub base_ref: String,
    pub head_ref: String,
    pub merge_base_sha: String,
    pub files: Vec<FileDiff>,
}

#[derive(Debug, Error)]
pub enum DiffError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("git command failed: {0}")]
    Git(String),
    #[error("git output was not valid utf-8: {0}")]
    Utf8(#[from] std::string::FromUtf8Error),
    #[error("diff parse error: {0}")]
    Parse(String),
    #[error("diff index out of bounds at file={file}, hunk={hunk}, line={line}")]
    OutOfBounds {
        file: usize,
        hunk: usize,
        line: usize,
    },
}

pub fn build_review_diff(
    repo_root: &Path,
    mode: ReviewMode,
    base_ref: &str,
    head_ref: &str,
    merge_base_sha: &str,
) -> Result<ReviewDiff, DiffError> {
    let mut command = Command::new("git");
    command.arg("-C").arg(repo_root);
    command.args(["diff", "--no-color", "--unified=3", "--no-ext-diff"]);
    match mode {
        ReviewMode::Branch => {
            command.arg(merge_base_sha);
            if !head_ref_points_to_current_head(repo_root, head_ref)? {
                // If the requested head ref is not checked out, we cannot include
                // local working tree changes and should diff merge-base to that ref.
                command.arg(head_ref);
            }
        }
        ReviewMode::Commit => {
            command.arg(base_ref);
            command.arg(head_ref);
        }
        ReviewMode::Uncommitted => {
            // Diff HEAD against the working tree, showing both staged and unstaged changes.
            command.arg("HEAD");
        }
    }
    let output = command.output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(DiffError::Git(stderr));
    }

    let payload = String::from_utf8(output.stdout)?;
    let files = parse_unified_diff(&payload)?;
    Ok(ReviewDiff {
        base_ref: base_ref.to_string(),
        head_ref: head_ref.to_string(),
        merge_base_sha: merge_base_sha.to_string(),
        files,
    })
}

fn head_ref_points_to_current_head(repo_root: &Path, head_ref: &str) -> Result<bool, DiffError> {
    let target_head = resolve_commit_sha(repo_root, head_ref)?;
    let current_head = resolve_commit_sha(repo_root, "HEAD")?;
    Ok(target_head == current_head)
}

fn resolve_commit_sha(repo_root: &Path, reference: &str) -> Result<String, DiffError> {
    let ref_name = format!("{reference}^{{commit}}");
    git_capture(repo_root, &["rev-parse", "--verify", &ref_name])
}

fn git_capture(repo_root: &Path, args: &[&str]) -> Result<String, DiffError> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(args)
        .output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(DiffError::Git(format!(
            "git {} failed: {stderr}",
            args.join(" ")
        )));
    }

    let stdout = String::from_utf8(output.stdout)?;
    Ok(stdout.trim().to_string())
}

pub fn parse_unified_diff(payload: &str) -> Result<Vec<FileDiff>, DiffError> {
    let mut files = Vec::<FileDiff>::new();
    let mut current_file: Option<FileDiff> = None;
    let mut current_hunk: Option<WorkingHunk> = None;

    for raw_line in payload.lines() {
        if raw_line.starts_with("diff --git ") {
            finalize_hunk(&mut current_file, &mut current_hunk)?;
            if let Some(file) = current_file.take() {
                files.push(file);
            }
            let (old_path, new_path) = parse_diff_header(raw_line)?;
            current_file = Some(FileDiff {
                old_path,
                new_path,
                hunks: Vec::new(),
            });
            continue;
        }

        if raw_line.starts_with("@@ ") {
            finalize_hunk(&mut current_file, &mut current_hunk)?;
            let parsed = parse_hunk_header(raw_line)?;
            current_hunk = Some(WorkingHunk {
                old_start: parsed.old_start,
                old_lines: parsed.old_lines,
                new_start: parsed.new_start,
                new_lines: parsed.new_lines,
                old_cursor: parsed.old_start,
                new_cursor: parsed.new_start,
                header: raw_line.to_string(),
                lines: Vec::new(),
            });
            continue;
        }

        if should_skip_metadata(raw_line) {
            continue;
        }

        if let Some(hunk) = current_hunk.as_mut() {
            if raw_line.starts_with('\\') {
                continue;
            }
            if raw_line.is_empty() {
                return Err(DiffError::Parse(
                    "unexpected empty diff line inside hunk".to_string(),
                ));
            }
            let marker = raw_line
                .chars()
                .next()
                .ok_or_else(|| DiffError::Parse("missing hunk line marker".to_string()))?;
            let content = raw_line
                .get(1..)
                .ok_or_else(|| DiffError::Parse("failed to extract hunk line content".to_string()))?
                .to_string();
            match marker {
                ' ' => {
                    let line = DiffLine {
                        kind: DiffLineKind::Context,
                        content,
                        old_line: Some(hunk.old_cursor),
                        new_line: Some(hunk.new_cursor),
                    };
                    hunk.old_cursor = hunk.old_cursor.saturating_add(1);
                    hunk.new_cursor = hunk.new_cursor.saturating_add(1);
                    hunk.lines.push(line);
                }
                '+' => {
                    let line = DiffLine {
                        kind: DiffLineKind::Added,
                        content,
                        old_line: None,
                        new_line: Some(hunk.new_cursor),
                    };
                    hunk.new_cursor = hunk.new_cursor.saturating_add(1);
                    hunk.lines.push(line);
                }
                '-' => {
                    let line = DiffLine {
                        kind: DiffLineKind::Removed,
                        content,
                        old_line: Some(hunk.old_cursor),
                        new_line: None,
                    };
                    hunk.old_cursor = hunk.old_cursor.saturating_add(1);
                    hunk.lines.push(line);
                }
                other => {
                    return Err(DiffError::Parse(format!(
                        "unexpected hunk line marker '{other}'"
                    )));
                }
            }
        }
    }

    finalize_hunk(&mut current_file, &mut current_hunk)?;
    if let Some(file) = current_file.take() {
        files.push(file);
    }
    Ok(files)
}

pub fn anchor_for_diff_line(file_path: &str, line: &DiffLine) -> CommentAnchor {
    CommentAnchor {
        file_path: Some(file_path.to_string()),
        line_new: line.new_line,
        line_old: line.old_line,
    }
}

pub fn anchor_at(
    diff: &ReviewDiff,
    file_index: usize,
    hunk_index: usize,
    line_index: usize,
) -> Result<CommentAnchor, DiffError> {
    let file = diff.files.get(file_index).ok_or(DiffError::OutOfBounds {
        file: file_index,
        hunk: hunk_index,
        line: line_index,
    })?;
    let hunk = file.hunks.get(hunk_index).ok_or(DiffError::OutOfBounds {
        file: file_index,
        hunk: hunk_index,
        line: line_index,
    })?;
    let line = hunk.lines.get(line_index).ok_or(DiffError::OutOfBounds {
        file: file_index,
        hunk: hunk_index,
        line: line_index,
    })?;
    Ok(anchor_for_diff_line(&file.new_path, line))
}

#[derive(Debug, Clone, Copy)]
struct ParsedHunk {
    old_start: u32,
    old_lines: u32,
    new_start: u32,
    new_lines: u32,
}

#[derive(Debug)]
struct WorkingHunk {
    old_start: u32,
    old_lines: u32,
    new_start: u32,
    new_lines: u32,
    old_cursor: u32,
    new_cursor: u32,
    header: String,
    lines: Vec<DiffLine>,
}

fn finalize_hunk(
    current_file: &mut Option<FileDiff>,
    current_hunk: &mut Option<WorkingHunk>,
) -> Result<(), DiffError> {
    if let Some(hunk) = current_hunk.take() {
        let file = current_file
            .as_mut()
            .ok_or_else(|| DiffError::Parse("encountered hunk before file header".to_string()))?;
        file.hunks.push(DiffHunk {
            header: hunk.header,
            old_start: hunk.old_start,
            old_lines: hunk.old_lines,
            new_start: hunk.new_start,
            new_lines: hunk.new_lines,
            lines: hunk.lines,
        });
    }
    Ok(())
}

fn parse_diff_header(line: &str) -> Result<(String, String), DiffError> {
    let header = line
        .strip_prefix("diff --git ")
        .ok_or_else(|| DiffError::Parse("missing diff --git header".to_string()))?;
    let mut parts = header.split_whitespace();
    let old_part = parts
        .next()
        .ok_or_else(|| DiffError::Parse("missing old path in diff header".to_string()))?;
    let new_part = parts
        .next()
        .ok_or_else(|| DiffError::Parse("missing new path in diff header".to_string()))?;

    let old_path = old_part.strip_prefix("a/").unwrap_or(old_part).to_string();
    let new_path = new_part.strip_prefix("b/").unwrap_or(new_part).to_string();
    Ok((old_path, new_path))
}

fn parse_hunk_header(line: &str) -> Result<ParsedHunk, DiffError> {
    let remaining = line
        .strip_prefix("@@ -")
        .ok_or_else(|| DiffError::Parse("invalid hunk header prefix".to_string()))?;
    let (ranges, _) = remaining
        .split_once(" @@")
        .ok_or_else(|| DiffError::Parse("missing hunk header separator".to_string()))?;
    let (old_range, new_range) = ranges
        .split_once(" +")
        .ok_or_else(|| DiffError::Parse("invalid hunk range pair".to_string()))?;
    let (old_start, old_lines) = parse_range(old_range)?;
    let (new_start, new_lines) = parse_range(new_range)?;
    Ok(ParsedHunk {
        old_start,
        old_lines,
        new_start,
        new_lines,
    })
}

fn parse_range(range: &str) -> Result<(u32, u32), DiffError> {
    let (start, lines) = match range.split_once(',') {
        Some((start, lines)) => (start, lines),
        None => (range, "1"),
    };
    let start = start
        .parse::<u32>()
        .map_err(|error| DiffError::Parse(format!("invalid range start '{start}': {error}")))?;
    let lines = lines
        .parse::<u32>()
        .map_err(|error| DiffError::Parse(format!("invalid range size '{lines}': {error}")))?;
    Ok((start, lines))
}

fn should_skip_metadata(line: &str) -> bool {
    [
        "index ",
        "--- ",
        "+++ ",
        "new file mode ",
        "deleted file mode ",
        "similarity index ",
        "rename from ",
        "rename to ",
        "Binary files ",
    ]
    .iter()
    .any(|prefix| line.starts_with(prefix))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::process::Command;

    use anyhow::{Context, Result, bail};
    use tempfile::TempDir;

    use super::*;

    #[test]
    fn parse_unified_diff_maps_hunks_and_line_numbers() -> Result<()> {
        let payload = "\
diff --git a/src/lib.rs b/src/lib.rs
index 1111111..2222222 100644
--- a/src/lib.rs
+++ b/src/lib.rs
@@ -1,3 +1,4 @@
 line1
-line2
+line2 changed
+line3
 line4
";
        let files = parse_unified_diff(payload)?;
        assert_eq!(files.len(), 1);
        let file = &files[0];
        assert_eq!(file.old_path, "src/lib.rs");
        assert_eq!(file.new_path, "src/lib.rs");
        assert_eq!(file.hunks.len(), 1);
        let hunk = &file.hunks[0];
        assert_eq!(hunk.old_start, 1);
        assert_eq!(hunk.new_start, 1);
        assert_eq!(hunk.lines.len(), 5);

        assert_eq!(hunk.lines[0].kind, DiffLineKind::Context);
        assert_eq!(hunk.lines[0].old_line, Some(1));
        assert_eq!(hunk.lines[0].new_line, Some(1));

        assert_eq!(hunk.lines[1].kind, DiffLineKind::Removed);
        assert_eq!(hunk.lines[1].old_line, Some(2));
        assert_eq!(hunk.lines[1].new_line, None);

        assert_eq!(hunk.lines[2].kind, DiffLineKind::Added);
        assert_eq!(hunk.lines[2].old_line, None);
        assert_eq!(hunk.lines[2].new_line, Some(2));
        Ok(())
    }

    #[test]
    fn parse_unified_diff_ignores_no_newline_marker() -> Result<()> {
        let payload = "\
diff --git a/a.txt b/a.txt
index 1111111..2222222 100644
--- a/a.txt
+++ b/a.txt
@@ -1 +1 @@
-old
+new
\\ No newline at end of file
";
        let files = parse_unified_diff(payload)?;
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].hunks[0].lines.len(), 2);
        Ok(())
    }

    #[test]
    fn anchor_at_maps_added_removed_and_context_lines() -> Result<()> {
        let payload = "\
diff --git a/src/lib.rs b/src/lib.rs
index 1111111..2222222 100644
--- a/src/lib.rs
+++ b/src/lib.rs
@@ -10,2 +10,3 @@
 keep
-remove
+add
 keep2
";
        let files = parse_unified_diff(payload)?;
        let diff = ReviewDiff {
            base_ref: "main".to_string(),
            head_ref: "feature".to_string(),
            merge_base_sha: "abc123".to_string(),
            files,
        };

        let context_anchor = anchor_at(&diff, 0, 0, 0)?;
        assert_eq!(context_anchor.file_path.as_deref(), Some("src/lib.rs"));
        assert_eq!(context_anchor.line_old, Some(10));
        assert_eq!(context_anchor.line_new, Some(10));

        let removed_anchor = anchor_at(&diff, 0, 0, 1)?;
        assert_eq!(removed_anchor.line_old, Some(11));
        assert_eq!(removed_anchor.line_new, None);

        let added_anchor = anchor_at(&diff, 0, 0, 2)?;
        assert_eq!(added_anchor.line_old, None);
        assert_eq!(added_anchor.line_new, Some(11));

        Ok(())
    }

    #[test]
    fn build_review_diff_branch_includes_committed_and_uncommitted() -> Result<()> {
        let repo = TempDir::new().context("temp repo")?;
        git(&repo, &["init"])?;
        git(&repo, &["config", "user.name", "Argon Test"])?;
        git(&repo, &["config", "user.email", "argon-test@example.com"])?;

        fs::write(repo.path().join("a.txt"), "one\n").context("write file")?;
        git(&repo, &["add", "a.txt"])?;
        git(&repo, &["commit", "-m", "init"])?;
        git(&repo, &["branch", "-M", "main"])?;
        git(&repo, &["checkout", "-b", "feature"])?;

        fs::write(repo.path().join("a.txt"), "one\ncommitted\n").context("write committed")?;
        git(&repo, &["commit", "-am", "committed change"])?;
        fs::write(repo.path().join("a.txt"), "one\ncommitted\nworking\n")
            .context("write uncommitted")?;

        let merge_base = git(&repo, &["merge-base", "main", "HEAD"])?;

        let diff = build_review_diff(
            repo.path(),
            crate::model::ReviewMode::Branch,
            "main",
            "HEAD",
            &merge_base,
        )?;
        assert_eq!(diff.files.len(), 1);
        assert_eq!(diff.files[0].new_path, "a.txt");
        let added = collect_added_lines(&diff);
        assert!(added.iter().any(|line| line == "committed"));
        assert!(added.iter().any(|line| line == "working"));
        Ok(())
    }

    #[test]
    fn build_review_diff_branch_uses_requested_head_when_not_checked_out() -> Result<()> {
        let repo = TempDir::new().context("temp repo")?;
        git(&repo, &["init"])?;
        git(&repo, &["config", "user.name", "Argon Test"])?;
        git(&repo, &["config", "user.email", "argon-test@example.com"])?;

        fs::write(repo.path().join("a.txt"), "one\n").context("write file")?;
        git(&repo, &["add", "a.txt"])?;
        git(&repo, &["commit", "-m", "init"])?;
        git(&repo, &["branch", "-M", "main"])?;
        git(&repo, &["checkout", "-b", "feature"])?;
        fs::write(repo.path().join("a.txt"), "one\nfeature\n").context("write feature")?;
        git(&repo, &["commit", "-am", "feature change"])?;
        git(&repo, &["checkout", "main"])?;
        fs::write(repo.path().join("a.txt"), "one\nmain-working\n")
            .context("write main working")?;

        let merge_base = git(&repo, &["merge-base", "main", "feature"])?;
        let diff = build_review_diff(
            repo.path(),
            crate::model::ReviewMode::Branch,
            "main",
            "feature",
            &merge_base,
        )?;
        let added = collect_added_lines(&diff);
        assert!(added.iter().any(|line| line == "feature"));
        assert!(!added.iter().any(|line| line == "main-working"));
        Ok(())
    }

    #[test]
    fn build_review_diff_commit_shows_latest_commit_only() -> Result<()> {
        let repo = TempDir::new().context("temp repo")?;
        git(&repo, &["init"])?;
        git(&repo, &["config", "user.name", "Argon Test"])?;
        git(&repo, &["config", "user.email", "argon-test@example.com"])?;

        fs::write(repo.path().join("a.txt"), "one\n").context("write file")?;
        git(&repo, &["add", "a.txt"])?;
        git(&repo, &["commit", "-m", "init"])?;
        fs::write(repo.path().join("a.txt"), "one\ncommitted\n").context("write committed")?;
        git(&repo, &["commit", "-am", "second"])?;
        let base = git(&repo, &["rev-parse", "HEAD~1"])?;
        let head = git(&repo, &["rev-parse", "HEAD"])?;

        fs::write(repo.path().join("a.txt"), "one\nworking\n").context("write uncommitted")?;

        let diff = build_review_diff(
            repo.path(),
            crate::model::ReviewMode::Commit,
            &base,
            &head,
            &head,
        )?;
        assert_eq!(diff.files.len(), 1);
        assert_eq!(diff.files[0].new_path, "a.txt");
        let added = collect_added_lines(&diff);
        assert!(added.iter().any(|line| line == "committed"));
        assert!(!added.iter().any(|line| line == "working"));
        Ok(())
    }

    #[test]
    fn build_review_diff_uncommitted_shows_staged_and_unstaged() -> Result<()> {
        let repo = TempDir::new().context("temp repo")?;
        git(&repo, &["init"])?;
        git(&repo, &["config", "user.name", "Argon Test"])?;
        git(&repo, &["config", "user.email", "argon-test@example.com"])?;

        // Create initial commit with a file.
        fs::write(repo.path().join("a.txt"), "one\n").context("write file")?;
        git(&repo, &["add", "a.txt"])?;
        git(&repo, &["commit", "-m", "init"])?;
        let head_sha = git(&repo, &["rev-parse", "HEAD"])?;

        // Stage a change (this line will be in the index but committed relative to HEAD).
        fs::write(repo.path().join("a.txt"), "one\nstaged\n").context("write staged")?;
        git(&repo, &["add", "a.txt"])?;

        // Make an additional unstaged change on top of the staged content.
        fs::write(repo.path().join("a.txt"), "one\nstaged\nunstaged\n")
            .context("write unstaged")?;

        let diff = build_review_diff(
            repo.path(),
            crate::model::ReviewMode::Uncommitted,
            &head_sha,
            "WORKTREE",
            &head_sha,
        )?;

        assert_eq!(diff.files.len(), 1);
        assert_eq!(diff.files[0].new_path, "a.txt");
        let added = collect_added_lines(&diff);
        assert!(
            added.iter().any(|line| line == "staged"),
            "expected staged change to appear in diff, got: {added:?}"
        );
        assert!(
            added.iter().any(|line| line == "unstaged"),
            "expected unstaged change to appear in diff, got: {added:?}"
        );
        Ok(())
    }

    fn collect_added_lines(diff: &ReviewDiff) -> Vec<String> {
        diff.files
            .iter()
            .flat_map(|file| file.hunks.iter())
            .flat_map(|hunk| hunk.lines.iter())
            .filter(|line| line.kind == DiffLineKind::Added)
            .map(|line| line.content.clone())
            .collect()
    }

    fn git(repo: &TempDir, args: &[&str]) -> Result<String> {
        let output = Command::new("git")
            .current_dir(repo.path())
            .args(args)
            .output()
            .with_context(|| format!("failed to run git {}", args.join(" ")))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            bail!("git {} failed: {stderr}", args.join(" "));
        }

        let stdout = String::from_utf8(output.stdout).context("git output was not utf-8")?;
        Ok(stdout.trim().to_string())
    }
}
