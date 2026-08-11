/* Atomic native-error capture witnesses for jolt.ffi. */
#ifndef _WIN32
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 199309L
#endif
#endif

#include <stdarg.h>
#include <stdint.h>

#ifdef _WIN32
#include <windows.h>
#define JOLT_NE_EXPORT __declspec(dllexport)
#define JOLT_NE_SET(code) SetLastError((DWORD)(code))
#else
#include <errno.h>
#include <time.h>
#define JOLT_NE_EXPORT __attribute__((visibility("default")))
#define JOLT_NE_SET(code) (errno = (int)(code))
#endif

JOLT_NE_EXPORT int jolt_ne_fail(int code) {
  JOLT_NE_SET(code);
  return -1;
}

JOLT_NE_EXPORT int jolt_ne_ok(void) {
  JOLT_NE_SET(0);
  return 7;
}

JOLT_NE_EXPORT int jolt_ne_clobber(int code) {
  JOLT_NE_SET(code);
  return 0;
}

/* Pins composition with v0.7.1's :varargs marker and (__varargs_after n). */
JOLT_NE_EXPORT int jolt_ne_variadic(int code, ...) {
  va_list args;
  int result;
  va_start(args, code);
  result = va_arg(args, int);
  va_end(args);
  JOLT_NE_SET(code);
  return result;
}

/* Stay native long enough for another Chez thread to force a collection. */
JOLT_NE_EXPORT int jolt_ne_block_fail(uint32_t millis, int code) {
#ifdef _WIN32
  Sleep((DWORD)millis);
#else
  struct timespec delay;
  delay.tv_sec = (time_t)(millis / 1000U);
  delay.tv_nsec = (long)(millis % 1000U) * 1000000L;
  while (nanosleep(&delay, &delay) == -1 && errno == EINTR) {
    /* Resume the remaining interval after a signal. */
  }
#endif
  JOLT_NE_SET(code);
  return -1;
}
