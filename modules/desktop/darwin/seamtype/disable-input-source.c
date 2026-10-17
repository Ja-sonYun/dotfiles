#include <Carbon/Carbon.h>
#include <stdbool.h>
#include <stdio.h>

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: seamtype-disable-input-source SOURCE_ID\n");
    return 1;
  }

  CFStringRef identifier =
      CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
  if (identifier == NULL) {
    return 1;
  }
  const void *keys[] = {kTISPropertyInputSourceID};
  const void *values[] = {identifier};
  CFDictionaryRef filter =
      CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                         &kCFTypeDictionaryValueCallBacks);
  CFArrayRef sources = TISCreateInputSourceList(filter, true);
  CFRelease(filter);
  CFRelease(identifier);
  if (sources == NULL) {
    fprintf(stderr, "Could not list input source: %s\n", argv[1]);
    return 1;
  }

  int result = 0;
  for (CFIndex index = 0; index < CFArrayGetCount(sources); index++) {
    TISInputSourceRef source =
        (TISInputSourceRef)CFArrayGetValueAtIndex(sources, index);
    CFBooleanRef enabled =
        TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled);
    if (enabled != NULL && CFBooleanGetValue(enabled)) {
      OSStatus status = TISDisableInputSource(source);
      if (status != noErr) {
        fprintf(stderr, "Could not disable input source %s: %d\n", argv[1],
                (int)status);
        result = 1;
      }
    }
  }
  CFRelease(sources);
  return result;
}
