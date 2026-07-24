#include <stdint.h>

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

int jolt_test_date_value(jolt_test_date_t value) {
    return value.year + value.month * 100 + value.day;
}

int jolt_test_datetime_value(jolt_test_datetime_t value) {
    return value.date.year
        + value.date.month * 100
        + value.date.day
        + value.time.hour * 10000
        + value.time.minute * 1000000
        + value.time.second * 100000000
        + (int) value.time.microsecond;
}

int jolt_test_date_size(void) {
    return (int) sizeof(jolt_test_date_t);
}

int jolt_test_datetime_size(void) {
    return (int) sizeof(jolt_test_datetime_t);
}
