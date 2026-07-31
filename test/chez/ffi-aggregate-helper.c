#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#include <windows.h>
#define JOLT_TEST_EXPORT __declspec(dllexport)
#else
#include <errno.h>
#define JOLT_TEST_EXPORT __attribute__((visibility("default")))
#endif

typedef struct {
    int32_t year;
    uint8_t month;
    uint8_t day;
} jolt_test_date_t;

typedef struct {
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
    uint32_t microsecond;
} jolt_test_time_t;

typedef struct {
    jolt_test_date_t date;
    jolt_test_time_t time;
} jolt_test_datetime_t;

static int jolt_test_date_score(jolt_test_date_t value) {
    return value.year + value.month * 100 + value.day;
}

static void jolt_test_set_native_error(int code) {
#ifdef _WIN32
    SetLastError((DWORD) code);
#else
    errno = code;
#endif
}

JOLT_TEST_EXPORT int jolt_test_date_value(jolt_test_date_t value) {
    return jolt_test_date_score(value);
}

JOLT_TEST_EXPORT int jolt_test_date_value_with_error(jolt_test_date_t value,
                                                     int code) {
    int result = -jolt_test_date_score(value);
    jolt_test_set_native_error(code);
    return result;
}

JOLT_TEST_EXPORT int jolt_test_date_plus_vararg(jolt_test_date_t value,
                                                int count, ...) {
    va_list args;
    int extra;
    if (count != 1) {
        return -1;
    }
    va_start(args, count);
    extra = va_arg(args, int);
    va_end(args);
    return jolt_test_date_score(value) + extra;
}

JOLT_TEST_EXPORT int jolt_test_datetime_value(jolt_test_datetime_t value) {
    return value.date.year
        + value.date.month * 100
        + value.date.day
        + value.time.hour * 10000
        + value.time.minute * 1000000
        + value.time.second * 100000000
        + (int) value.time.microsecond;
}

JOLT_TEST_EXPORT int jolt_test_datetime_value_with_error(
    jolt_test_datetime_t value, int code) {
    int result = -jolt_test_datetime_value(value);
    jolt_test_set_native_error(code);
    return result;
}

JOLT_TEST_EXPORT int32_t jolt_test_datetime_probe(
    jolt_test_datetime_t value, int32_t count, ...) {
    va_list args;
    int sentinel = 0;
    int32_t result;

    if (count == 1) {
        va_start(args, count);
        sentinel = va_arg(args, int);
        va_end(args);
    }

    if (count != 1) {
        result = -2;
    } else if (value.date.year == INT32_C(-123456789)
               && value.date.month == UINT8_C(250)
               && value.date.day == UINT8_C(251)
               && value.time.hour == UINT8_C(252)
               && value.time.minute == UINT8_C(253)
               && value.time.second == UINT8_C(254)
               && value.time.microsecond == UINT32_C(4045620583)
               && sentinel == 37) {
        result = -1;
    } else {
        result = -3;
    }

    jolt_test_set_native_error(19003);
    return result;
}

JOLT_TEST_EXPORT int32_t jolt_test_date_year(jolt_test_date_t value) {
    return value.year;
}

JOLT_TEST_EXPORT uint32_t jolt_test_datetime_microsecond(
    jolt_test_datetime_t value) {
    return value.time.microsecond;
}

JOLT_TEST_EXPORT int jolt_test_date_size(void) {
    return (int) sizeof(jolt_test_date_t);
}

JOLT_TEST_EXPORT int jolt_test_time_size(void) {
    return (int) sizeof(jolt_test_time_t);
}

JOLT_TEST_EXPORT int jolt_test_datetime_size(void) {
    return (int) sizeof(jolt_test_datetime_t);
}

JOLT_TEST_EXPORT int jolt_test_datetime_time_offset(void) {
    return (int) offsetof(jolt_test_datetime_t, time);
}

JOLT_TEST_EXPORT int jolt_test_time_microsecond_offset(void) {
    return (int) offsetof(jolt_test_time_t, microsecond);
}
