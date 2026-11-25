#pragma once
#include <stdatomic.h>
#include <stdint.h>
#define BW_AUDIO_MAGIC 0x42574156
#define BW_AUDIO_FRAMES 32768
#define BW_AUDIO_CHANNELS 64
// Independent single-producer rings in each direction, laid out by channel.
typedef struct {
    uint32_t magic;
    _Atomic uint32_t channels,bufferFrames,inputChannels;
    _Atomic double sampleRate,outputLatency,inputLatency;
    _Atomic uint64_t routeGeneration;
    _Atomic uint64_t readFrame,writeFrame,callbacks,audibleFrames,underrunFrames;
    _Atomic uint64_t requestedGeneration,engineActiveGeneration;
    _Atomic int actualRunning,error,engineActivePID;
    _Atomic uint64_t inputReadFrame,inputWriteFrame,inputFrames,inputNonzeroFrames,inputDeliveredFrames,inputDroppedFrames;
    _Atomic int inputError;
    float samples[BW_AUDIO_CHANNELS][BW_AUDIO_FRAMES];
    float inputSamples[BW_AUDIO_CHANNELS][BW_AUDIO_FRAMES];
} BWAudioRing;

static inline uint64_t BWAudioQueued(uint64_t write, uint64_t read) {
    return write >= read && write - read <= BW_AUDIO_FRAMES ? write - read : 0;
}
