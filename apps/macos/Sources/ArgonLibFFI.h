#ifndef ARGON_LIB_FFI_H
#define ARGON_LIB_FFI_H

#include <stdint.h>

char *argonlib_resolve_interactive_path_json(
  const char *environment_json,
  uint64_t timeout_ms
);
void argonlib_string_free(char *value);

#endif
