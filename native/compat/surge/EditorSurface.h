#pragma once

#include <stdint.h>

enum {
    BWEditorSurfaceVersion = 3,
    BWEditorMaxWidth = 1536,
    BWEditorMaxHeight = 1024,
    BWEditorPointerCapacity = 64,
    BWEditorKeyTextCapacity = 16,
};

typedef struct {
    float x, y;
    uint8_t phase;
    uint8_t repeat, held;
    uint16_t keyCode;
    uint32_t modifiers;
    uint8_t textLength, unmodifiedLength;
    uint16_t text[BWEditorKeyTextCapacity], unmodified[BWEditorKeyTextCapacity];
} BWEditorInput;

enum {
    BWEditorPointerDown = 1, BWEditorPointerUp = 2,
    BWEditorSecondaryDown = 3, BWEditorSecondaryUp = 4,
    BWEditorPointerMove = 6, BWEditorSecondaryMove = 7,
    BWEditorKeyDown = 10, BWEditorKeyUp = 11, BWEditorKeyFlags = 12,
};

// Both processes hold an advisory file lock while reading or updating this
// mapping. It is only accessed by UI work and never from render callbacks.
typedef struct {
    uint32_t version;
    uint32_t width, height, stride;
    uint32_t pointsWide, pointsHigh;
    uint64_t sequence;
    double heartbeat;
    double foregroundHeartbeat;
    uint8_t visible, closeRequested, cancelRequested, fabFilter;
    uint8_t pointerRead, pointerCount;
    BWEditorInput pointers[BWEditorPointerCapacity];
    uint8_t pixels[BWEditorMaxWidth * BWEditorMaxHeight * 4];
} BWEditorSurface;
