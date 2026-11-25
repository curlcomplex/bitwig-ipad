#include <ColorSync/ColorSync.h>
#include <stdint.h>

// VSTGUI draws into the iPad bridge's standard sRGB bitmap.
ColorSyncProfileRef ColorSyncProfileCreateWithDisplayID(uint32_t display) {
    return ColorSyncProfileCreateWithName(kColorSyncSRGBProfile);
}
