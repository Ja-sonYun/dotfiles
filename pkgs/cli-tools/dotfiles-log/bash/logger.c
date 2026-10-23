#include "builtins.h"
#include "client.h"
#include "config.h"
#include "shell.h"

int dotfiles_log_builtin(WORD_LIST *list) {
  const char *arguments[4];
  for (size_t i = 0; i < 4; i++) {
    if (!list) {
      return EXECUTION_SUCCESS;
    }
    arguments[i] = list->word->word;
    list = list->next;
  }

  dfl_frame frame;
  if (!dfl_begin(&frame, arguments[1], arguments[2], arguments[3])) {
    return EXECUTION_SUCCESS;
  }
  for (; list; list = list->next) {
    const char *field = list->word->word;
    const char *value = strchr(field, '=');
    if (!value ||
        !dfl_field(&frame, field, (size_t)(value - field), value + 1)) {
      return EXECUTION_SUCCESS;
    }
  }
  dfl_send(arguments[0], &frame);
  return EXECUTION_SUCCESS;
}

void dotfiles_log_builtin_unload(char *name) {
  (void)name;
  dfl_disconnect();
}

static char *documentation[] = {
    "Send a diagnostic event without waiting; unavailable or congested loggers "
    "drop it.",
    NULL,
};

struct builtin dotfiles_log_struct = {
    "dotfiles_log",
    dotfiles_log_builtin,
    BUILTIN_ENABLED,
    documentation,
    "dotfiles_log SOCKET COMPONENT LEVEL EVENT [KEY=VALUE ...]",
    NULL,
};
