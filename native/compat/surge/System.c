#include <libkern/OSCacheControl.h>
#include <stdint.h>

void __clear_cache(void *start, void *end) {
    if ((uintptr_t)end > (uintptr_t)start)
        sys_icache_invalidate(start, (uintptr_t)end - (uintptr_t)start);
}
