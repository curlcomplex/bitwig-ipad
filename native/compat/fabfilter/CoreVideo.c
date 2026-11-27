#include <stdint.h>

int32_t CVDisplayLinkSetCurrentCGDisplay(void *link, uint32_t display) {
    if (!link) return -6661;
    // The shared bridge creates a display link for the single logical display.
    return display == 1 ? 0 : -6662;
}
