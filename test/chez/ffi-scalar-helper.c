#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
#include <windows.h>
#define JOLT_TEST_EXPORT __declspec(dllexport)
#else
#include <errno.h>
#include <time.h>
#define JOLT_TEST_EXPORT __attribute__((visibility("default")))
#endif

JOLT_TEST_EXPORT int64_t jolt_test_widen_i8(int8_t value) { return value; }
JOLT_TEST_EXPORT int64_t jolt_test_widen_i16(int16_t value) { return value; }
JOLT_TEST_EXPORT uint64_t jolt_test_widen_u16(uint16_t value) { return value; }
JOLT_TEST_EXPORT int64_t jolt_test_widen_i32(int32_t value) { return value; }
JOLT_TEST_EXPORT uint64_t jolt_test_widen_u32(uint32_t value) { return value; }

JOLT_TEST_EXPORT int8_t jolt_test_return_i8(void) { return INT8_MIN; }
JOLT_TEST_EXPORT int16_t jolt_test_return_i16(void) { return INT16_MIN; }
JOLT_TEST_EXPORT uint16_t jolt_test_return_u16(void) { return UINT16_MAX; }
JOLT_TEST_EXPORT int32_t jolt_test_return_i32(void) { return INT32_MIN; }
JOLT_TEST_EXPORT uint32_t jolt_test_return_u32(void) { return UINT32_MAX; }

JOLT_TEST_EXPORT void *jolt_test_fill_bytes(void *pointer, uint8_t value,
                                            size_t count) {
  uint8_t *bytes = (uint8_t *)pointer;
  for (size_t i = 0; i < count; ++i) {
    bytes[i] = value;
  }
  return pointer;
}

typedef int8_t (*jolt_test_i8_callback)(int8_t);
typedef int16_t (*jolt_test_i16_callback)(int16_t);
typedef uint16_t (*jolt_test_u16_callback)(uint16_t);
typedef int32_t (*jolt_test_i32_callback)(int32_t);
typedef uint32_t (*jolt_test_u32_callback)(uint32_t);

JOLT_TEST_EXPORT int64_t jolt_test_call_i8(jolt_test_i8_callback callback) {
  return callback(INT8_MIN);
}

JOLT_TEST_EXPORT int64_t jolt_test_call_i16(jolt_test_i16_callback callback) {
  return callback(INT16_MIN);
}

JOLT_TEST_EXPORT uint64_t jolt_test_call_u16(jolt_test_u16_callback callback) {
  return callback(UINT16_MAX);
}

JOLT_TEST_EXPORT int64_t jolt_test_call_i32(jolt_test_i32_callback callback) {
  return callback(INT32_MIN);
}

JOLT_TEST_EXPORT uint64_t jolt_test_call_u32(jolt_test_u32_callback callback) {
  return callback(UINT32_MAX);
}

JOLT_TEST_EXPORT void jolt_test_sleep_millis(uint32_t milliseconds) {
#ifdef _WIN32
  Sleep(milliseconds);
#else
  struct timespec remaining = {
      (time_t)(milliseconds / 1000),
      (long)(milliseconds % 1000) * 1000000L,
  };
  while (nanosleep(&remaining, &remaining) == -1 && errno == EINTR) {
  }
#endif
}

/* Atomic native-error capture helpers. Each is a default-C-ABI (cdecl) entry
   point so Chez's foreign-procedure calls it directly. They exercise the
   thread-local native error slot that POSIX errno and Win32 GetLastError share
   (Winsock exposes the same slot through WSAGetLastError), keeping the test
   platform-neutral: no direct Winsock/WinAPI binding from Jolt is needed.

   jolt_test_set_error_fail writes a known code to the slot and returns a failure
   sentinel, so a captured binding pairs [-1 code]. ENOENT (2) on POSIX and
   ERROR_FILE_NOT_FOUND (2) on Windows are deliberately the same integer, so the
   gate asserts (= code 2) on every host. jolt_test_overwrite_error then mutates
   the SAME slot to a different code (EINVAL=22 / ERROR_INVALID_PARAMETER=87) to
   prove the saved pair is immutable: a later native call can change the current
   slot but cannot touch the values already captured in the foreign-call return
   path. */
JOLT_TEST_EXPORT int jolt_test_set_error_fail(void) {
#ifdef _WIN32
  SetLastError(ERROR_FILE_NOT_FOUND);
#else
  errno = ENOENT;
#endif
  return -1;
}

JOLT_TEST_EXPORT void jolt_test_overwrite_error(void) {
#ifdef _WIN32
  SetLastError(ERROR_INVALID_PARAMETER);
#else
  errno = EINVAL;
#endif
}
