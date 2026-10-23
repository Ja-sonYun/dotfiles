#ifndef DOTFILES_LOG_CLIENT_H
#define DOTFILES_LOG_CLIENT_H

#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define DFL_FRAME_LIMIT (32 * 1024)

typedef struct {
  char data[DFL_FRAME_LIMIT];
  size_t used;
  int fields;
} dfl_frame;

static int dfl_connection = -1;
static pid_t dfl_owner;
static char dfl_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static pthread_mutex_t dfl_mutex = PTHREAD_MUTEX_INITIALIZER;

static inline void dfl_disconnect(void) {
  if (dfl_connection >= 0) {
    close(dfl_connection);
  }
  dfl_connection = -1;
}

static inline int dfl_text(dfl_frame *frame, const char *text) {
  size_t length = strlen(text);
  if (frame->used + length > sizeof(frame->data)) {
    return 0;
  }
  memcpy(frame->data + frame->used, text, length);
  frame->used += length;
  return 1;
}

static inline int dfl_string(dfl_frame *frame, const char *text,
                             size_t length) {
  if (!dfl_text(frame, "\"")) {
    return 0;
  }
  for (size_t i = 0; i < length; i++) {
    unsigned char c = (unsigned char)text[i];
    char escaped[7];
    if (c < 32) {
      snprintf(escaped, sizeof(escaped), "\\u%04x", c);
    } else if (c == '\\' || c == '"') {
      escaped[0] = '\\';
      escaped[1] = (char)c;
      escaped[2] = 0;
    } else {
      escaped[0] = (char)c;
      escaped[1] = 0;
    }
    if (!dfl_text(frame, escaped)) {
      return 0;
    }
  }
  return dfl_text(frame, "\"");
}

static inline int dfl_begin(dfl_frame *frame, const char *component,
                            const char *level, const char *event) {
  struct timespec now;
  struct tm utc;
  char timestamp[64], prefix[160];
  frame->used = 0;
  frame->fields = 0;
  if (clock_gettime(CLOCK_REALTIME, &now) != 0 ||
      !gmtime_r(&now.tv_sec, &utc)) {
    return 0;
  }
  strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S", &utc);
  snprintf(prefix, sizeof(prefix),
           "{\"time\":\"%s.%03ldZ\",\"pid\":%ld,\"component\":", timestamp,
           now.tv_nsec / 1000000, (long)getpid());
  return dfl_text(frame, prefix) &&
         dfl_string(frame, component, strlen(component)) &&
         dfl_text(frame, ",\"level\":") &&
         dfl_string(frame, level, strlen(level)) &&
         dfl_text(frame, ",\"event\":") &&
         dfl_string(frame, event, strlen(event)) &&
         dfl_text(frame, ",\"fields\":{");
}

static inline int dfl_field(dfl_frame *frame, const char *key,
                            size_t key_length, const char *value) {
  if ((frame->fields && !dfl_text(frame, ",")) ||
      !dfl_string(frame, key, key_length) || !dfl_text(frame, ":") ||
      !dfl_string(frame, value, strlen(value))) {
    return 0;
  }
  frame->fields++;
  return 1;
}

static inline void dfl_send(const char *path, dfl_frame *frame) {
  // A short write closes the connection so the next event starts a new frame.
  if (!path || !*path || strlen(path) >= sizeof(dfl_path) ||
      !dfl_text(frame, "}}\n") || pthread_mutex_trylock(&dfl_mutex) != 0) {
    return;
  }
  if (dfl_owner != getpid() || strcmp(dfl_path, path) != 0) {
    dfl_disconnect();
  }
  if (dfl_connection < 0) {
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
#ifdef __APPLE__
    address.sun_len = sizeof(address);
#endif
    strcpy(address.sun_path, path);
    dfl_connection = socket(AF_UNIX, SOCK_STREAM, 0);
    if (dfl_connection < 0 || fcntl(dfl_connection, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(dfl_connection, F_SETFL, O_NONBLOCK) < 0) {
      goto failed;
    }
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    if (setsockopt(dfl_connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                   sizeof(enabled)) < 0) {
      goto failed;
    }
#endif
    if (connect(dfl_connection, (struct sockaddr *)&address, sizeof(address)) <
        0) {
      goto failed;
    }
    dfl_owner = getpid();
    strcpy(dfl_path, path);
  }
  int flags = 0;
#ifdef MSG_NOSIGNAL
  flags = MSG_NOSIGNAL;
#endif
  if (send(dfl_connection, frame->data, frame->used, flags) !=
      (ssize_t)frame->used) {
    goto failed;
  }
  pthread_mutex_unlock(&dfl_mutex);
  return;

failed:
  dfl_disconnect();
  pthread_mutex_unlock(&dfl_mutex);
}

static inline void dfl_logv(const char *path, const char *component,
                            const char *level, const char *event,
                            const char *format, va_list arguments) {
  if (!path || !*path) {
    return;
  }
  char message[DFL_FRAME_LIMIT];
  int length = vsnprintf(message, sizeof(message), format, arguments);
  if (length < 0 || (size_t)length >= sizeof(message)) {
    return;
  }
  while (length > 0 && message[length - 1] == '\n') {
    message[--length] = 0;
  }
  dfl_frame frame;
  if (dfl_begin(&frame, component, level, event) &&
      dfl_field(&frame, "message", 7, message)) {
    dfl_send(path, &frame);
  }
}

#endif
