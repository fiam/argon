use serde::{Deserialize, Serialize};
use std::ffi::OsStr;
use std::path::Path;

use syntect::highlighting::{Theme, ThemeSet};
use syntect::parsing::SyntaxSet;

use crate::diff::{DiffLineKind, FileDiff, ReviewDiff};

/// A styled text span with an optional foreground color.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StyledSpan {
    pub text: String,
    /// Hex color like "#ff0000", or None for default.
    pub fg: Option<String>,
    pub bold: bool,
    pub italic: bool,
    /// True if this span represents a word-level change within a modified line.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub changed: bool,
}

/// A diff line with syntax-highlighted spans.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HighlightedLine {
    pub kind: DiffLineKind,
    pub old_line: Option<u32>,
    pub new_line: Option<u32>,
    pub spans: Vec<StyledSpan>,
}

/// A hunk in unified view.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HighlightedHunk {
    pub header: String,
    pub lines: Vec<HighlightedLine>,
}

/// A row in side-by-side view.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SideBySidePair {
    pub left: Option<HighlightedLine>,
    pub right: Option<HighlightedLine>,
}

/// A highlighted file diff with both unified and side-by-side representations.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HighlightedFileDiff {
    pub old_path: String,
    pub new_path: String,
    pub unified_hunks: Vec<HighlightedHunk>,
    pub side_by_side: Vec<SideBySidePair>,
    pub added_count: usize,
    pub removed_count: usize,
}

/// The complete highlighted diff.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HighlightedDiff {
    pub base_ref: String,
    pub head_ref: String,
    pub files: Vec<HighlightedFileDiff>,
}

/// Available theme names.
pub fn available_themes() -> Vec<String> {
    let ts: ThemeSet = two_face::theme::extra().into();
    ts.themes.keys().cloned().collect()
}

/// Highlight arbitrary text using the syntax inferred from a virtual file path.
pub fn highlight_text(text: &str, path: &str, theme_name: &str) -> Vec<Vec<StyledSpan>> {
    if text.is_empty() {
        return Vec::new();
    }

    let ss = two_face::syntax::extra_newlines();
    let ts: ThemeSet = two_face::theme::extra().into();
    let theme = ts.themes.get(theme_name).unwrap_or_else(|| {
        ts.themes
            .get("base16-ocean.dark")
            .expect("default theme must exist")
    });
    let syntax = syntax_for_virtual_path(&ss, path);
    let mut highlighter = syntect::easy::HighlightLines::new(syntax, theme);

    text.split('\n')
        .map(|line| {
            let line_with_newline = format!("{line}\n");
            highlight_line_content(&mut highlighter, &ss, &line_with_newline)
        })
        .collect()
}

/// Highlight a parsed diff with syntax coloring.
pub fn highlight_diff(diff: &ReviewDiff, theme_name: &str) -> HighlightedDiff {
    let ss = two_face::syntax::extra_newlines();
    let ts: ThemeSet = two_face::theme::extra().into();
    let theme = ts.themes.get(theme_name).unwrap_or_else(|| {
        ts.themes
            .get("base16-ocean.dark")
            .expect("default theme must exist")
    });

    let files = diff
        .files
        .iter()
        .map(|file| highlight_file(file, &ss, theme))
        .collect();

    HighlightedDiff {
        base_ref: diff.base_ref.clone(),
        head_ref: diff.head_ref.clone(),
        files,
    }
}

fn highlight_file(file: &FileDiff, ss: &SyntaxSet, theme: &Theme) -> HighlightedFileDiff {
    let syntax = syntax_for_virtual_path(ss, &file.new_path);

    let mut highlighter = syntect::easy::HighlightLines::new(syntax, theme);

    let mut unified_hunks = Vec::new();
    let mut all_unified_lines = Vec::new();
    let mut added_count = 0;
    let mut removed_count = 0;

    for hunk in &file.hunks {
        let mut highlighted_lines = Vec::new();

        for line in &hunk.lines {
            match line.kind {
                DiffLineKind::Added => added_count += 1,
                DiffLineKind::Removed => removed_count += 1,
                DiffLineKind::Context => {}
            }

            let line_with_newline = format!("{}\n", line.content);
            let spans = highlight_line_content(&mut highlighter, ss, &line_with_newline);

            let hl = HighlightedLine {
                kind: line.kind,
                old_line: line.old_line,
                new_line: line.new_line,
                spans,
            };
            highlighted_lines.push(hl.clone());
            all_unified_lines.push(hl);
        }

        unified_hunks.push(HighlightedHunk {
            header: hunk.header.clone(),
            lines: highlighted_lines,
        });
    }

    // Apply word-level change marks to unified hunks
    mark_word_changes_in_unified(&mut unified_hunks);

    // Rebuild all_unified_lines from the now-marked hunks
    let marked_lines: Vec<_> = unified_hunks.iter().flat_map(|h| h.lines.clone()).collect();
    let side_by_side = build_side_by_side(&marked_lines);

    HighlightedFileDiff {
        old_path: file.old_path.clone(),
        new_path: file.new_path.clone(),
        unified_hunks,
        side_by_side,
        added_count,
        removed_count,
    }
}

fn syntax_for_virtual_path<'a>(
    ss: &'a SyntaxSet,
    path: &str,
) -> &'a syntect::parsing::SyntaxReference {
    Path::new(path)
        .extension()
        .and_then(OsStr::to_str)
        .and_then(|extension| ss.find_syntax_by_extension(extension))
        .or_else(|| {
            Path::new(path)
                .file_name()
                .and_then(OsStr::to_str)
                .and_then(|name| ss.find_syntax_by_token(name))
        })
        .unwrap_or_else(|| ss.find_syntax_plain_text())
}

fn highlight_line_content(
    highlighter: &mut syntect::easy::HighlightLines,
    ss: &SyntaxSet,
    content: &str,
) -> Vec<StyledSpan> {
    match highlighter.highlight_line(content, ss) {
        Ok(ranges) => ranges
            .into_iter()
            .map(|(style, text)| {
                let fg = format!(
                    "#{:02x}{:02x}{:02x}",
                    style.foreground.r, style.foreground.g, style.foreground.b
                );
                StyledSpan {
                    text: text.trim_end_matches('\n').to_string(),
                    fg: Some(fg),
                    bold: style
                        .font_style
                        .contains(syntect::highlighting::FontStyle::BOLD),
                    italic: style
                        .font_style
                        .contains(syntect::highlighting::FontStyle::ITALIC),
                    changed: false,
                }
            })
            .filter(|span| !span.text.is_empty())
            .collect(),
        Err(_) => vec![StyledSpan {
            text: content.trim_end_matches('\n').to_string(),
            fg: None,
            bold: false,
            italic: false,
            changed: false,
        }],
    }
}

/// Build side-by-side pairs from unified diff lines, with word-level
/// change highlighting on paired removed+added lines.
fn build_side_by_side(lines: &[HighlightedLine]) -> Vec<SideBySidePair> {
    let mut result = Vec::new();
    let mut i = 0;

    while i < lines.len() {
        match lines[i].kind {
            DiffLineKind::Context => {
                result.push(SideBySidePair {
                    left: Some(lines[i].clone()),
                    right: Some(lines[i].clone()),
                });
                i += 1;
            }
            DiffLineKind::Removed => {
                let mut removed = Vec::new();
                while i < lines.len() && lines[i].kind == DiffLineKind::Removed {
                    removed.push(lines[i].clone());
                    i += 1;
                }
                let mut added = Vec::new();
                while i < lines.len() && lines[i].kind == DiffLineKind::Added {
                    added.push(lines[i].clone());
                    i += 1;
                }
                let max_len = removed.len().max(added.len());
                for j in 0..max_len {
                    let left = removed.get(j).cloned();
                    let right = added.get(j).cloned();

                    // Apply word-level diff when we have a pair
                    let (left, right) = match (left, right) {
                        (Some(l), Some(r)) => {
                            let (wl, wr) = mark_word_changes(&l, &r);
                            (Some(wl), Some(wr))
                        }
                        pair => pair,
                    };

                    result.push(SideBySidePair { left, right });
                }
            }
            DiffLineKind::Added => {
                result.push(SideBySidePair {
                    left: None,
                    right: Some(lines[i].clone()),
                });
                i += 1;
            }
        }
    }

    result
}

/// Also mark word-level changes in the unified hunks (for unified view).
fn mark_word_changes_in_unified(hunks: &mut [HighlightedHunk]) {
    for hunk in hunks.iter_mut() {
        let mut i = 0;
        while i < hunk.lines.len() {
            if hunk.lines[i].kind == DiffLineKind::Removed {
                let rem_start = i;
                while i < hunk.lines.len() && hunk.lines[i].kind == DiffLineKind::Removed {
                    i += 1;
                }
                let add_start = i;
                while i < hunk.lines.len() && hunk.lines[i].kind == DiffLineKind::Added {
                    i += 1;
                }
                let rem_end = add_start;
                let add_end = i;

                let pair_count = (rem_end - rem_start).min(add_end - add_start);
                for j in 0..pair_count {
                    let (new_rem, new_add) =
                        mark_word_changes(&hunk.lines[rem_start + j], &hunk.lines[add_start + j]);
                    hunk.lines[rem_start + j] = new_rem;
                    hunk.lines[add_start + j] = new_add;
                }
            } else {
                i += 1;
            }
        }
    }
}

/// Given a removed line and an added line, compute word-level diffs and
/// return new lines with `changed: true` on the differing spans.
fn mark_word_changes(
    old_line: &HighlightedLine,
    new_line: &HighlightedLine,
) -> (HighlightedLine, HighlightedLine) {
    let old_text = spans_to_text(&old_line.spans);
    let new_text = spans_to_text(&new_line.spans);

    let old_words = tokenize_for_diff(&old_text);
    let new_words = tokenize_for_diff(&new_text);

    let lcs = longest_common_subsequence(&old_words, &new_words);

    let old_changed = mark_changed_regions(&old_words, &lcs, true);
    let new_changed = mark_changed_regions(&new_words, &lcs, false);

    let old_spans = apply_change_marks(&old_line.spans, &old_changed);
    let new_spans = apply_change_marks(&new_line.spans, &new_changed);

    (
        HighlightedLine {
            kind: old_line.kind,
            old_line: old_line.old_line,
            new_line: old_line.new_line,
            spans: old_spans,
        },
        HighlightedLine {
            kind: new_line.kind,
            old_line: new_line.old_line,
            new_line: new_line.new_line,
            spans: new_spans,
        },
    )
}

fn spans_to_text(spans: &[StyledSpan]) -> String {
    spans.iter().map(|s| s.text.as_str()).collect()
}

/// Tokenize a string into words and whitespace for diffing.
fn tokenize_for_diff(text: &str) -> Vec<&str> {
    let mut tokens = Vec::new();
    let mut start = 0;
    let bytes = text.as_bytes();

    while start < bytes.len() {
        if bytes[start].is_ascii_alphanumeric() || bytes[start] == b'_' {
            let end = (start + 1..bytes.len())
                .find(|&i| !(bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_'))
                .unwrap_or(bytes.len());
            tokens.push(&text[start..end]);
            start = end;
        } else {
            tokens.push(&text[start..start + 1]);
            start += 1;
        }
    }

    tokens
}

/// LCS of token slices.
fn longest_common_subsequence<'a>(a: &[&'a str], b: &[&'a str]) -> Vec<&'a str> {
    let m = a.len();
    let n = b.len();
    let mut dp = vec![vec![0u32; n + 1]; m + 1];

    for i in 1..=m {
        for j in 1..=n {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1;
            } else {
                dp[i][j] = dp[i - 1][j].max(dp[i][j - 1]);
            }
        }
    }

    let mut result = Vec::new();
    let mut i = m;
    let mut j = n;
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] {
            result.push(a[i - 1]);
            i -= 1;
            j -= 1;
        } else if dp[i - 1][j] > dp[i][j - 1] {
            i -= 1;
        } else {
            j -= 1;
        }
    }
    result.reverse();
    result
}

/// For each character position, determine if it's changed (not in LCS).
fn mark_changed_regions(tokens: &[&str], lcs: &[&str], is_old: bool) -> Vec<bool> {
    let _ = is_old;
    let mut changed = Vec::new();
    let mut lcs_idx = 0;

    for token in tokens {
        if lcs_idx < lcs.len() && *token == lcs[lcs_idx] {
            changed.extend(std::iter::repeat_n(false, token.len()));
            lcs_idx += 1;
        } else {
            changed.extend(std::iter::repeat_n(true, token.len()));
        }
    }

    changed
}

/// Split existing spans according to the per-character change marks.
fn apply_change_marks(spans: &[StyledSpan], char_changed: &[bool]) -> Vec<StyledSpan> {
    let mut result = Vec::new();
    let mut char_idx = 0;

    for span in spans {
        let span_len = span.text.len();
        if char_idx + span_len > char_changed.len() {
            // Safety: if marks are shorter than text, treat rest as unchanged
            result.push(span.clone());
            char_idx += span_len;
            continue;
        }

        // Split this span into changed and unchanged segments
        let mut seg_start = 0;
        while seg_start < span_len {
            let is_changed = char_changed[char_idx + seg_start];
            let mut seg_end = seg_start + 1;
            while seg_end < span_len
                && char_idx + seg_end < char_changed.len()
                && char_changed[char_idx + seg_end] == is_changed
            {
                seg_end += 1;
            }

            result.push(StyledSpan {
                text: span.text[seg_start..seg_end].to_string(),
                fg: span.fg.clone(),
                bold: span.bold,
                italic: span.italic,
                changed: is_changed,
            });

            seg_start = seg_end;
        }

        char_idx += span_len;
    }

    result
}

/// Detect the appropriate syntect theme for the current system appearance.
pub fn theme_for_appearance(dark: bool) -> &'static str {
    if dark {
        "base16-ocean.dark"
    } else {
        "base16-ocean.light"
    }
}

#[cfg(test)]
mod tests {
    use crate::diff::{DiffHunk, DiffLine, DiffLineKind, FileDiff, ReviewDiff};

    use super::*;

    fn sample_diff() -> ReviewDiff {
        ReviewDiff {
            base_ref: "main".to_string(),
            head_ref: "feature".to_string(),
            merge_base_sha: "abc123".to_string(),
            files: vec![FileDiff {
                old_path: "src/main.rs".to_string(),
                new_path: "src/main.rs".to_string(),
                hunks: vec![DiffHunk {
                    header: "@@ -1,3 +1,4 @@".to_string(),
                    old_start: 1,
                    old_lines: 3,
                    new_start: 1,
                    new_lines: 4,
                    lines: vec![
                        DiffLine {
                            kind: DiffLineKind::Context,
                            content: "fn main() {".to_string(),
                            old_line: Some(1),
                            new_line: Some(1),
                        },
                        DiffLine {
                            kind: DiffLineKind::Removed,
                            content: "    println!(\"hello\");".to_string(),
                            old_line: Some(2),
                            new_line: None,
                        },
                        DiffLine {
                            kind: DiffLineKind::Added,
                            content: "    println!(\"hello world\");".to_string(),
                            old_line: None,
                            new_line: Some(2),
                        },
                        DiffLine {
                            kind: DiffLineKind::Added,
                            content: "    println!(\"goodbye\");".to_string(),
                            old_line: None,
                            new_line: Some(3),
                        },
                        DiffLine {
                            kind: DiffLineKind::Context,
                            content: "}".to_string(),
                            old_line: Some(3),
                            new_line: Some(4),
                        },
                    ],
                }],
            }],
        }
    }

    #[test]
    fn highlight_produces_styled_spans() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");

        assert_eq!(result.files.len(), 1);
        let file = &result.files[0];
        assert_eq!(file.new_path, "src/main.rs");
        assert_eq!(file.unified_hunks.len(), 1);

        let hunk = &file.unified_hunks[0];
        assert_eq!(hunk.lines.len(), 5);

        // Each line should have at least one span
        for line in &hunk.lines {
            assert!(!line.spans.is_empty(), "line should have spans");
        }

        // Check that spans have foreground colors
        let first_line_spans = &hunk.lines[0].spans;
        assert!(first_line_spans.iter().any(|s| s.fg.is_some()));
    }

    #[test]
    fn highlight_preserves_line_kinds() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");

        let lines = &result.files[0].unified_hunks[0].lines;
        assert_eq!(lines[0].kind, DiffLineKind::Context);
        assert_eq!(lines[1].kind, DiffLineKind::Removed);
        assert_eq!(lines[2].kind, DiffLineKind::Added);
        assert_eq!(lines[3].kind, DiffLineKind::Added);
        assert_eq!(lines[4].kind, DiffLineKind::Context);
    }

    #[test]
    fn highlight_preserves_line_numbers() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");

        let lines = &result.files[0].unified_hunks[0].lines;
        assert_eq!(lines[0].old_line, Some(1));
        assert_eq!(lines[0].new_line, Some(1));
        assert_eq!(lines[1].old_line, Some(2));
        assert_eq!(lines[1].new_line, None);
        assert_eq!(lines[2].old_line, None);
        assert_eq!(lines[2].new_line, Some(2));
    }

    #[test]
    fn highlight_counts_additions_and_removals() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");

        let file = &result.files[0];
        assert_eq!(file.added_count, 2);
        assert_eq!(file.removed_count, 1);
    }

    #[test]
    fn side_by_side_pairs_removed_and_added() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");

        let pairs = &result.files[0].side_by_side;
        // Context: fn main() {
        assert!(pairs[0].left.is_some());
        assert!(pairs[0].right.is_some());
        assert_eq!(pairs[0].left.as_ref().unwrap().kind, DiffLineKind::Context);

        // Removed paired with first added
        assert!(pairs[1].left.is_some());
        assert!(pairs[1].right.is_some());
        assert_eq!(pairs[1].left.as_ref().unwrap().kind, DiffLineKind::Removed);
        assert_eq!(pairs[1].right.as_ref().unwrap().kind, DiffLineKind::Added);

        // Second added with no left
        assert!(pairs[2].left.is_none());
        assert!(pairs[2].right.is_some());
        assert_eq!(pairs[2].right.as_ref().unwrap().kind, DiffLineKind::Added);

        // Context: }
        assert!(pairs[3].left.is_some());
        assert!(pairs[3].right.is_some());
        assert_eq!(pairs[3].left.as_ref().unwrap().kind, DiffLineKind::Context);
    }

    #[test]
    fn side_by_side_unpaired_removed() {
        let lines = vec![
            HighlightedLine {
                kind: DiffLineKind::Removed,
                old_line: Some(1),
                new_line: None,
                spans: vec![StyledSpan {
                    text: "old".to_string(),
                    fg: None,
                    bold: false,
                    italic: false,
                    changed: false,
                }],
            },
            HighlightedLine {
                kind: DiffLineKind::Removed,
                old_line: Some(2),
                new_line: None,
                spans: vec![StyledSpan {
                    text: "old2".to_string(),
                    fg: None,
                    bold: false,
                    italic: false,
                    changed: false,
                }],
            },
        ];

        let pairs = build_side_by_side(&lines);
        assert_eq!(pairs.len(), 2);
        assert!(pairs[0].left.is_some());
        assert!(pairs[0].right.is_none());
        assert!(pairs[1].left.is_some());
        assert!(pairs[1].right.is_none());
    }

    #[test]
    fn side_by_side_equal_removed_added() {
        let lines = vec![
            HighlightedLine {
                kind: DiffLineKind::Removed,
                old_line: Some(1),
                new_line: None,
                spans: vec![StyledSpan {
                    text: "old".to_string(),
                    fg: None,
                    bold: false,
                    italic: false,
                    changed: false,
                }],
            },
            HighlightedLine {
                kind: DiffLineKind::Added,
                old_line: None,
                new_line: Some(1),
                spans: vec![StyledSpan {
                    text: "new".to_string(),
                    fg: None,
                    bold: false,
                    italic: false,
                    changed: false,
                }],
            },
        ];

        let pairs = build_side_by_side(&lines);
        assert_eq!(pairs.len(), 1);
        assert!(pairs[0].left.is_some());
        assert!(pairs[0].right.is_some());
    }

    #[test]
    fn spans_text_concatenated_equals_original_content() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");

        let original_lines: Vec<&str> = diff.files[0].hunks[0]
            .lines
            .iter()
            .map(|l| l.content.as_str())
            .collect();

        let highlighted_lines = &result.files[0].unified_hunks[0].lines;
        for (orig, hl) in original_lines.iter().zip(highlighted_lines.iter()) {
            let reconstructed: String = hl.spans.iter().map(|s| s.text.as_str()).collect();
            assert_eq!(
                &reconstructed, orig,
                "highlighted spans should reconstruct original text"
            );
        }
    }

    #[test]
    fn available_themes_includes_defaults() {
        let themes = available_themes();
        assert!(themes.contains(&"base16-ocean.dark".to_string()));
        assert!(themes.contains(&"base16-ocean.light".to_string()));
    }

    #[test]
    fn highlight_handles_plain_text_file() {
        let diff = ReviewDiff {
            base_ref: "HEAD".to_string(),
            head_ref: "WORKTREE".to_string(),
            merge_base_sha: "abc".to_string(),
            files: vec![FileDiff {
                old_path: "README.md".to_string(),
                new_path: "README.md".to_string(),
                hunks: vec![DiffHunk {
                    header: "@@ -1 +1,2 @@".to_string(),
                    old_start: 1,
                    old_lines: 1,
                    new_start: 1,
                    new_lines: 2,
                    lines: vec![
                        DiffLine {
                            kind: DiffLineKind::Context,
                            content: "# Hello".to_string(),
                            old_line: Some(1),
                            new_line: Some(1),
                        },
                        DiffLine {
                            kind: DiffLineKind::Added,
                            content: "World".to_string(),
                            old_line: None,
                            new_line: Some(2),
                        },
                    ],
                }],
            }],
        };

        let result = highlight_diff(&diff, "base16-ocean.dark");
        assert_eq!(result.files.len(), 1);
        assert_eq!(result.files[0].unified_hunks[0].lines.len(), 2);
    }

    #[test]
    fn highlight_serializes_to_json() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");
        let json = serde_json::to_string(&result).expect("should serialize");
        let deserialized: HighlightedDiff =
            serde_json::from_str(&json).expect("should deserialize");
        assert_eq!(deserialized.files.len(), result.files.len());
    }

    #[test]
    fn highlight_text_uses_virtual_file_extension() {
        let result = highlight_text(
            "font-size = 14\n# comment\n",
            "ghostty.ini",
            "base16-ocean.dark",
        );

        assert_eq!(result.len(), 3);
        assert_eq!(
            result[0]
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>(),
            "font-size = 14"
        );
        assert_eq!(
            result[1]
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>(),
            "# comment"
        );
        assert!(result[0].iter().any(|span| span.fg.is_some()));
    }

    #[test]
    fn word_level_changes_marked_in_paired_lines() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");

        // The sample diff has:
        //   - println!("hello");
        //   + println!("hello world");
        // The word "world" should be marked as changed in the added line,
        // and nothing extra in the removed line beyond what differs.

        // Check unified hunks have some changed spans
        let hunk = &result.files[0].unified_hunks[0];
        let removed_line = &hunk.lines[1]; // removed
        let added_line = &hunk.lines[2]; // first added

        let removed_has_changes = removed_line.spans.iter().any(|s| s.changed);
        let added_has_changes = added_line.spans.iter().any(|s| s.changed);
        assert!(
            removed_has_changes || added_has_changes,
            "paired removed/added lines should have word-level change marks"
        );
    }

    #[test]
    fn word_level_changes_in_side_by_side() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");

        // The paired row should have changed spans
        let pair = &result.files[0].side_by_side[1]; // removed+added pair
        let left = pair.left.as_ref().unwrap();
        let right = pair.right.as_ref().unwrap();

        let left_has_changes = left.spans.iter().any(|s| s.changed);
        let right_has_changes = right.spans.iter().any(|s| s.changed);
        assert!(
            left_has_changes || right_has_changes,
            "side-by-side paired lines should have word-level change marks"
        );
    }

    #[test]
    fn tokenize_splits_words_and_punctuation() {
        let tokens = tokenize_for_diff("hello(world, 42)");
        assert_eq!(tokens, vec!["hello", "(", "world", ",", " ", "42", ")"]);
    }

    #[test]
    fn context_lines_have_no_changed_marks() {
        let diff = sample_diff();
        let result = highlight_diff(&diff, "base16-ocean.dark");

        let context_line = &result.files[0].unified_hunks[0].lines[0]; // "fn main() {"
        assert!(
            !context_line.spans.iter().any(|s| s.changed),
            "context lines should have no changed marks"
        );
    }
}
