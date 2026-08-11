#include <stddef.h>
#include <stdint.h>

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
