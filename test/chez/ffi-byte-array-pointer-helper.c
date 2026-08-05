/* Portable C write witness for the scoped byte-array pointer loan gate.
 *
 * jolt_test_fill_bytes writes `value` into the first `count` octets of the
 * pointer it is handed and returns that pointer. The jolt.ffi scope hands it a
 * borrowed pointer into a private locked bytevector; the loan's copy-back is
 * what makes that native write observable in the jolt byte-array afterward.
 *
 * It performs a real C write through a real pointer without depending on any
 * errno/GetLastError convention or on the jolt byte-array's own memory layout
 * (the pointer never points at the signed vector backing the array). Mirrors
 * the layout of test/chez/ffi-widths-helper.c and ffi-native-error-test.c
 * (export macro, no tree pollution, stdint-clean). */
#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
#define JOLT_BAP_EXPORT __declspec(dllexport)
#else
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
