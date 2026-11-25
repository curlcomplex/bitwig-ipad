#pragma once

#include <stdint.h>

enum {
    BWEditorSurfaceVersion = 1,
    BWEditorMaxWidth = 1536,
    BWEditorMaxHeight = 1024,
    BWEditorPointerCapacity = 64,
};

typedef struct {
    float x, y;
    uint8_t phase;
} BWEditorPointer;

enum { BWEditorPointerDown = 1, BWEditorPointerUp = 2, BWEditorPointerMove = 6 };

// Both processes hold an advisory file lock while reading or updating this
// mapping. It is only accessed by UI work and never from render callbacks.
typedef struct {
    uint32_t version;
    uint32_t width, height, stride;
    uint32_t pointsWide, pointsHigh;
    uint64_t sequence;
    double heartbeat;
    uint8_t visible, closeRequested;
    uint8_t pointerRead, pointerCount;
    BWEditorPointer pointers[BWEditorPointerCapacity];
    uint8_t pixels[BWEditorMaxWidth * BWEditorMaxHeight * 4];
} BWEditorSurface;
