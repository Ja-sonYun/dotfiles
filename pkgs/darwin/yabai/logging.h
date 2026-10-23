#ifndef YABAI_DOTFILES_LOG_H
#define YABAI_DOTFILES_LOG_H

#include "dotfiles_log_client.h"

static bool g_dotfiles_logging;

static inline void yabai_logv(FILE *stream, const char *level,
                              const char *event, const char *format,
                              va_list arguments) {
  if (g_dotfiles_logging) {
    dfl_logv(getenv("DOTFILES_LOG_SOCKET"), "yabai", level, event, format,
             arguments);
  } else {
    vfprintf(stream, format, arguments);
  }
}

static inline void yabai_log(FILE *stream, const char *level, const char *event,
                             const char *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  yabai_logv(stream, level, event, format, arguments);
  va_end(arguments);
}

#endif
