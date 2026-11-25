#include <stdint.h>
#include <time.h>

uint32_t TickCount(void) {
    // Carbon measures sixty ticks per second from a monotonic clock.
    uint64_t nanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    return (uint32_t)(nanoseconds / 1000000000 * 60 + nanoseconds % 1000000000 * 60 / 1000000000);
}
