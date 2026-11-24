#pragma once
#include <stdatomic.h>
#include <stdint.h>
#define BW_AUDIO_MAGIC 0x42574155
#define BW_AUDIO_FRAMES 32768
#define BW_AUDIO_CHANNELS 2
// One original-engine producer and one foreground RemoteIO consumer.
typedef struct {
    uint32_t magic,channels,bufferFrames,reserved;
    double sampleRate,outputLatency;
    _Atomic uint64_t readFrame,writeFrame,callbacks,audibleFrames,underrunFrames;
    _Atomic int requestedRunning,actualRunning,error;
    float samples[BW_AUDIO_FRAMES*BW_AUDIO_CHANNELS];
} BWAudioRing;
