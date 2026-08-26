/* Portable C write witness for the scoped byte-array pointer loan gate.
 *
 * jolt_test_fill_bytes writes `value` into the first `count` octets of the
 * pointer it is handed and returns that pointer. The jolt.ffi scope hands it a
 * borrowed pointer into a private locked bytevector; the loan's copy-back is
 * what makes that native write observable in the jolt byte-array afterward.
 *
 * jolt_test_fill_bytes_error additionally leaves a requested errno/GetLastError
 * value at return, so the gate can prove atomic native-error capture composes
 * with the loan's later copy-back and unlock cleanup.
 *
 * Neither function depends on the jolt byte-array's own memory layout (the
 * pointer never points at the signed vector backing the array). Mirrors
 * test/chez/ffi-widths-helper.c: an explicit export macro, no tree pollution,
 * and fixed-width C types. */
#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
#include <windows.h>
#define JOLT_BAP_EXPORT __declspec(dllexport)
#else
#include <errno.h>
#define JOLT_BAP_EXPORT __attribute__((visibility("default")))
#endif

JOLT_BAP_EXPORT void *jolt_test_fill_bytes(void *pointer, uint8_t value,
                                           size_t count) {
  uint8_t *bytes = (uint8_t *)pointer;
  for (size_t i = 0; i < count; ++i) {
    bytes[i] = value;
  }
  return pointer;
}

JOLT_BAP_EXPORT int jolt_test_fill_bytes_error(void *pointer, uint8_t value,
                                                size_t count, int error_code) {
  jolt_test_fill_bytes(pointer, value, count);
#ifdef _WIN32
  SetLastError((DWORD)error_code);
#else
  errno = error_code;
#endif
  return -1;
}
