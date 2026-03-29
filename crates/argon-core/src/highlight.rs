use serde::{Deserialize, Serialize};
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
    let ts = ThemeSet::load_defaults();
    ts.themes.keys().cloned().collect()
}

/// Highlight a parsed diff with syntax coloring.
pub fn highlight_diff(diff: &ReviewDiff, theme_name: &str) -> HighlightedDiff {
    let ss = SyntaxSet::load_defaults_newlines();
    let ts = ThemeSet::load_defaults();
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
    let syntax = ss
        .find_syntax_for_file(&file.new_path)
        .ok()
        .flatten()
        .unwrap_or_else(|| ss.find_syntax_plain_text());

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

    let side_by_side = build_side_by_side(&all_unified_lines);

    HighlightedFileDiff {
        old_path: file.old_path.clone(),
        new_path: file.new_path.clone(),
        unified_hunks,
        side_by_side,
        added_count,
        removed_count,
    }
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
                }
            })
            .filter(|span| !span.text.is_empty())
            .collect(),
        Err(_) => vec![StyledSpan {
            text: content.trim_end_matches('\n').to_string(),
            fg: None,
            bold: false,
            italic: false,
        }],
    }
}

/// Build side-by-side pairs from unified diff lines.
///
/// Rules:
/// - Context lines appear on both sides.
/// - Consecutive removed+added blocks are paired row-by-row.
/// - Unpaired removed lines have `right = None`.
/// - Unpaired added lines have `left = None`.
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
                // Collect consecutive removed lines
                let mut removed = Vec::new();
                while i < lines.len() && lines[i].kind == DiffLineKind::Removed {
                    removed.push(lines[i].clone());
                    i += 1;
                }
                // Collect consecutive added lines that follow
                let mut added = Vec::new();
                while i < lines.len() && lines[i].kind == DiffLineKind::Added {
                    added.push(lines[i].clone());
                    i += 1;
                }
                // Pair them
                let max_len = removed.len().max(added.len());
                for j in 0..max_len {
                    result.push(SideBySidePair {
                        left: removed.get(j).cloned(),
                        right: added.get(j).cloned(),
                    });
                }
            }
            DiffLineKind::Added => {
                // Added without preceding removed
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
}
