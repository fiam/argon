#ifndef ARGON_LIB_FFI_H
#define ARGON_LIB_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define ARGON_DIFF_LINE_CONTEXT 0
#define ARGON_DIFF_LINE_ADDED 1
#define ARGON_DIFF_LINE_REMOVED 2

typedef struct ArgonStyledSpan {
  char *text;
  char *fg;
  bool bold;
  bool italic;
  bool changed;
} ArgonStyledSpan;

typedef struct ArgonHighlightedLine {
  uint32_t kind;
  bool old_line_present;
  uint32_t old_line;
  bool new_line_present;
  uint32_t new_line;
  ArgonStyledSpan *spans;
  size_t span_count;
} ArgonHighlightedLine;

typedef struct ArgonHighlightedText {
  ArgonHighlightedLine *lines;
  size_t line_count;
} ArgonHighlightedText;

typedef struct ArgonHighlightedHunk {
  char *header;
  uint32_t old_start;
  uint32_t old_line_count;
  uint32_t new_start;
  uint32_t new_line_count;
  ArgonHighlightedLine *lines;
  size_t line_count;
} ArgonHighlightedHunk;

typedef struct ArgonSideBySidePair {
  ArgonHighlightedLine *left;
  ArgonHighlightedLine *right;
} ArgonSideBySidePair;

typedef struct ArgonHighlightedFile {
  char *old_path;
  char *new_path;
  ArgonHighlightedHunk *unified_hunks;
  size_t unified_hunk_count;
  ArgonSideBySidePair *side_by_side;
  size_t side_by_side_count;
  size_t added_count;
  size_t removed_count;
} ArgonHighlightedFile;

typedef struct ArgonHighlightedDiff {
  char *base_ref;
  char *head_ref;
  ArgonHighlightedFile *files;
  size_t file_count;
} ArgonHighlightedDiff;

typedef struct ArgonEnvironmentEntry {
  const char *key;
  const char *value;
} ArgonEnvironmentEntry;

char *argonlib_resolve_interactive_path(
  const ArgonEnvironmentEntry *entries,
  size_t entry_count,
  uint64_t timeout_ms
);

ArgonHighlightedText *argonlib_highlight_text(
  const char *text,
  const char *path,
  const char *theme,
  char **error_out
);

void argonlib_highlighted_text_free(ArgonHighlightedText *value);

ArgonHighlightedDiff *argonlib_highlight_diff_for_session(
  const char *repo_root,
  const char *session_id,
  const char *theme,
  char **error_out
);

void argonlib_highlighted_diff_free(ArgonHighlightedDiff *value);

void argonlib_string_free(char *value);

#endif
