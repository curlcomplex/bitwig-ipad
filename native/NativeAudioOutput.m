#import "compat/LocalConfiguration.h"
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include "NativeAudioShared.h"

static BWAudioRing *ring;
static AudioUnit output;
static dispatch_source_t audioTimer;
static NSURL *audioDirectory;
static NSDictionary *route, *configuredRoute;
static AudioBufferList *captureBuffers;
static float *captureSamples;
static UInt32 captureCapacity;
static BOOL engineDetached, clearCaptureOnIdle;

void BWStopAudioOutput(void) {
    if (!ring) return;
    atomic_store(&ring->requestedGeneration, 0);
    engineDetached = YES;
    clearCaptureOnIdle = YES;
}

static void captureInput(BWAudioRing *r, const AudioTimeStamp *time, UInt32 frames) {
    if (!captureBuffers) return;
    if (frames > captureCapacity) {
        atomic_fetch_add(&r->inputDroppedFrames, frames);
        return;
    }
    UInt32 channels = atomic_load_explicit(&r->inputChannels, memory_order_relaxed);
    for (UInt32 channel = 0; channel < channels; channel++)
        captureBuffers->mBuffers[channel].mDataByteSize = frames * sizeof(float);
    AudioUnitRenderActionFlags flags = 0;
    OSStatus result = AudioUnitRender(output, &flags, time, 1, frames, captureBuffers);
    atomic_store(&r->inputError, result);
    if (result) return;
    uint64_t write = atomic_load_explicit(&r->inputWriteFrame, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&r->inputReadFrame, memory_order_acquire);
    UInt32 count = (UInt32)MIN((uint64_t)frames, BW_AUDIO_FRAMES - BWAudioQueued(write, read));
    uint64_t nonzero = 0;
    for (UInt32 frame = 0; frame < count; frame++) {
        BOOL signal = NO;
        for (UInt32 channel = 0; channel < channels; channel++) {
            float value = ((float *)captureBuffers->mBuffers[channel].mData)[frame];
            r->inputSamples[channel][(write + frame) % BW_AUDIO_FRAMES] = value;
            signal |= value != 0;
        }
        nonzero += signal;
    }
    atomic_store_explicit(&r->inputWriteFrame, write + count, memory_order_release);
    atomic_fetch_add(&r->inputFrames, frames);
    atomic_fetch_add(&r->inputNonzeroFrames, nonzero);
    atomic_fetch_add(&r->inputDroppedFrames, frames - count);
}

static OSStatus render(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                       UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
    BWAudioRing *r = context;
    captureInput(r, time, frames);
    uint64_t read = atomic_load_explicit(&r->readFrame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&r->writeFrame, memory_order_acquire);
    UInt32 count = (UInt32)MIN((uint64_t)frames, BWAudioQueued(write, read));
    uint64_t audible = 0;
    UInt32 channels = atomic_load_explicit(&r->channels, memory_order_relaxed);
    for (UInt32 frame = 0; frame < frames; frame++) {
        BOOL signal = NO;
        for (UInt32 channel = 0; channel < channels; channel++) {
            float value = frame < count ? r->samples[channel][(read + frame) % BW_AUDIO_FRAMES] : 0;
            ((float *)buffers->mBuffers[channel].mData)[frame] = value;
            signal |= value != 0;
        }
        audible += signal;
    }
    atomic_store_explicit(&r->readFrame, read + count, memory_order_release);
    atomic_fetch_add(&r->callbacks, 1);
    atomic_fetch_add(&r->audibleFrames, audible);
    atomic_fetch_add(&r->underrunFrames, frames - count);
    return noErr;
}

static OSStatus inputOnly(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                          UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
    captureInput(context, time, frames);
    return noErr;
}

static AudioStreamBasicDescription pcmFormat(double rate, UInt32 channels) {
    return (AudioStreamBasicDescription){
        .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = sizeof(float), .mFramesPerPacket = 1, .mBytesPerFrame = sizeof(float),
        .mChannelsPerFrame = channels, .mBitsPerChannel = 32
    };
}

static void disposeUnit(void) {
    if (output) {
        AudioOutputUnitStop(output);
        AudioUnitUninitialize(output);
        AudioComponentInstanceDispose(output);
        output = NULL;
    }
    free(captureBuffers);
    free(captureSamples);
    captureBuffers = NULL;
    captureSamples = NULL;
    atomic_store(&ring->actualRunning, 0);
}

static NSDictionary *describeRoute(AVAudioSession *session) {
    AVAudioSessionPortDescription *source = session.currentRoute.inputs.firstObject;
    AVAudioSessionPortDescription *sink = session.currentRoute.outputs.firstObject;
    BOOL permission = AVAudioApplication.sharedInstance.recordPermission == AVAudioApplicationRecordPermissionGranted;
    return @{
        @"name": sink.portName ?: source.portName ?: @"iPad audio",
        @"uid": sink.UID ?: source.UID ?: @"",
        @"type": sink.portType ?: source.portType ?: @"",
        @"input_name": source.portName ?: @"",
        @"input_uid": source.UID ?: @"",
        @"input_type": source.portType ?: @"",
        @"input_authorized": @(permission),
        @"input_channels": @(permission && source ? session.inputNumberOfChannels : 0),
        @"input_latency": @(session.inputLatency),
        @"rate": @(session.sampleRate),
        @"channels": @(sink ? session.outputNumberOfChannels : 0),
        @"frames": @(llround(session.IOBufferDuration * session.sampleRate)),
        @"latency": @(session.outputLatency)
    };
}

static OSStatus configureRoute(AVAudioSession *session, BOOL force) {
    NSDictionary *next = describeRoute(session);
    if (!force && [next isEqual:configuredRoute]) return noErr;

    // Invalidate the route, stop its writer/reader, and let the existing
    // engine callback finish before reusing shared buffers.
    uint64_t generation = atomic_load(&ring->routeGeneration);
    if (!(generation & 1)) {
        generation = atomic_fetch_add_explicit(&ring->routeGeneration, 1, memory_order_acq_rel) + 1;
        atomic_store(&ring->requestedGeneration, 0);
        disposeUnit();
    }
    if (atomic_load_explicit(&ring->engineActiveGeneration, memory_order_acquire))
        return kAudioUnitErr_CannotDoInCurrentContext;
    memset(ring->inputSamples, 0, sizeof(float) * BW_AUDIO_FRAMES * MIN(ring->inputChannels, BW_AUDIO_CHANNELS));
    ring->channels = [next[@"channels"] unsignedIntValue];
    ring->inputChannels = [next[@"input_channels"] unsignedIntValue];
    ring->sampleRate = [next[@"rate"] doubleValue];
    ring->bufferFrames = [next[@"frames"] unsignedIntValue];
    ring->inputLatency = [next[@"input_latency"] doubleValue];
    ring->outputLatency = [next[@"latency"] doubleValue];

    OSStatus result = noErr;
    if (ring->channels > BW_AUDIO_CHANNELS || ring->inputChannels > BW_AUDIO_CHANNELS ||
        ring->sampleRate <= 0 || !ring->bufferFrames || ring->bufferFrames > 4096 ||
        (!ring->channels && !ring->inputChannels)) result = kAudioUnitErr_FormatNotSupported;
    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output, .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple
    };
    if (!result) {
        AudioComponent component = AudioComponentFindNext(NULL, &description);
        result = component ? AudioComponentInstanceNew(component, &output) : kAudioUnitErr_FailedInitialization;
    }
    if (!result && ring->inputChannels) {
        UInt32 enabled = 1;
        result = AudioUnitSetProperty(output, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1, &enabled, sizeof(enabled));
        AudioStreamBasicDescription format = pcmFormat(ring->sampleRate, ring->inputChannels);
        if (!result) result = AudioUnitSetProperty(output, kAudioUnitProperty_StreamFormat,
                                                   kAudioUnitScope_Output, 1, &format, sizeof(format));
        captureCapacity = 4096;
        captureBuffers = calloc(1, offsetof(AudioBufferList, mBuffers) + ring->inputChannels * sizeof(AudioBuffer));
        captureSamples = calloc((size_t)captureCapacity * ring->inputChannels, sizeof(float));
        if (!captureBuffers || !captureSamples) result = -108;
        if (!result) {
            captureBuffers->mNumberBuffers = ring->inputChannels;
            for (UInt32 channel = 0; channel < ring->inputChannels; channel++)
                captureBuffers->mBuffers[channel] = (AudioBuffer){1, captureCapacity * sizeof(float), captureSamples + channel * captureCapacity};
        }
    }
    if (!result && ring->channels) {
        AudioStreamBasicDescription format = pcmFormat(ring->sampleRate, ring->channels);
        result = AudioUnitSetProperty(output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
        AURenderCallbackStruct callback = {render, ring};
        if (!result) result = AudioUnitSetProperty(output, kAudioUnitProperty_SetRenderCallback,
                                                   kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    }
    if (!result && !ring->channels) {
        UInt32 enabled = 0;
        result = AudioUnitSetProperty(output, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &enabled, sizeof(enabled));
        AURenderCallbackStruct callback = {inputOnly, ring};
        if (!result) result = AudioUnitSetProperty(output, kAudioOutputUnitProperty_SetInputCallback,
                                                   kAudioUnitScope_Global, 0, &callback, sizeof(callback));
    }
    if (!result) result = AudioUnitInitialize(output);
    if (result) disposeUnit();

    NSMutableDictionary *published = [next mutableCopy];
    published[@"generation"] = @(generation + 1);
    if (result) {
        published[@"channels"] = @0;
        published[@"input_channels"] = @0;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:published options:0 error:nil];
    if (![data writeToURL:[audioDirectory URLByAppendingPathComponent:@"route.json"] atomically:YES]) {
        disposeUnit();
        atomic_store(&ring->error, kAudioUnitErr_FailedInitialization);
        // Keep this generation unavailable until its matching metadata is
        // published. The host timer can retry without exposing the old file.
        return kAudioUnitErr_FailedInitialization;
    }
    configuredRoute = result ? nil : next;
    route = [published copy];
    atomic_store(&ring->error, result);
    atomic_store(&ring->inputError, 0);
    atomic_fetch_add_explicit(&ring->routeGeneration, 1, memory_order_release);
    NSLog(@"Native audio route format status=%d rate=%.0f inputs=%u outputs=%u frames=%u",
          (int)result, ring->sampleRate, ring->inputChannels, ring->channels, ring->bufferFrames);
    return result;
}

static void finishIdleCapture(void) {
    if (atomic_load(&ring->actualRunning)) return;
    if (engineDetached) {
        uint64_t generation = atomic_load_explicit(&ring->engineActiveGeneration, memory_order_acquire);
        pid_t pid = atomic_load_explicit(&ring->engineActivePID, memory_order_acquire);
        if (generation && pid > 0 && kill(pid, 0) != 0 && errno == ESRCH) {
            atomic_store_explicit(&ring->engineActivePID, 0, memory_order_relaxed);
            atomic_compare_exchange_strong(&ring->engineActiveGeneration, &generation, 0);
        }
        if (!atomic_load(&ring->engineActiveGeneration)) engineDetached = NO;
    }
    if (clearCaptureOnIdle && !atomic_load_explicit(&ring->engineActiveGeneration, memory_order_acquire)) {
        memset(ring->inputSamples, 0, sizeof(float) * BW_AUDIO_FRAMES * MIN(ring->inputChannels, BW_AUDIO_CHANNELS));
        clearCaptureOnIdle = NO;
    }
}

BOOL BWPrepareAudioOutput(void) {
    if (ring) {
        finishIdleCapture();
        return output != NULL;
    }
    AVAudioSession *session = AVAudioSession.sharedInstance;
    BOOL permission = AVAudioApplication.sharedInstance.recordPermission == AVAudioApplicationRecordPermissionGranted;
    AVAudioSessionCategory category = permission ? AVAudioSessionCategoryPlayAndRecord : AVAudioSessionCategoryPlayback;
    AVAudioSessionCategoryOptions options = permission ? AVAudioSessionCategoryOptionDefaultToSpeaker |
        AVAudioSessionCategoryOptionAllowBluetoothHFP | AVAudioSessionCategoryOptionAllowBluetoothA2DP : 0;
    NSError *error = nil;
    if (![session setCategory:category mode:AVAudioSessionModeDefault options:options error:&error] ||
        ![session setActive:YES error:&error]) {
        NSLog(@"Native audio session failed: %@", error);
        return NO;
    }
    audioDirectory = [BWSharedContainerURL() URLByAppendingPathComponent:@"BitwigUser/Audio" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:audioDirectory withIntermediateDirectories:YES attributes:nil error:&error])
        return NO;
    NSString *ringPath = [[audioDirectory URLByAppendingPathComponent:@"ring.bin"] path];
    // Upgrade the ABI via an atomic file replacement. Older process mappings,
    // should they still exist, retain the previous inode until they exit.
    NSString *replacement = [ringPath stringByAppendingString:@".new"];
    int fd = open(replacement.fileSystemRepresentation, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) return NO;
    void *memory = MAP_FAILED;
    if (!ftruncate(fd, sizeof(BWAudioRing)))
        memory = mmap(NULL, sizeof(BWAudioRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (memory == MAP_FAILED) return NO;
    if (rename(replacement.fileSystemRepresentation, ringPath.fileSystemRepresentation)) {
        munmap(memory, sizeof(BWAudioRing));
        return NO;
    }
    [[NSURL fileURLWithPath:ringPath] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    ring = memory;
    ring->magic = BW_AUDIO_MAGIC;
    OSStatus initial = configureRoute(session, YES);

    for (NSString *name in @[AVAudioSessionRouteChangeNotification, AVAudioSessionMediaServicesWereResetNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:session queue:NSOperationQueue.mainQueue
           usingBlock:^(NSNotification *note) {
            BOOL reset = [note.name isEqualToString:AVAudioSessionMediaServicesWereResetNotification];
            if (reset) {
                [session setCategory:category mode:AVAudioSessionModeDefault options:options error:nil];
                [session setActive:YES error:nil];
            }
            configureRoute(session, reset);
        }];
    }
    NSString *status = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                         stringByAppendingPathComponent:@"native-audio.json"];
    audioTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(audioTimer, DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    __block NSUInteger ticks = 0;
    dispatch_source_set_event_handler(audioTimer, ^{
        finishIdleCapture();
        if ((atomic_load(&ring->routeGeneration) & 1) && ticks % 5 == 0) configureRoute(session, YES);
        uint64_t generation = atomic_load(&ring->routeGeneration);
        uint64_t requested = atomic_load(&ring->requestedGeneration);
        int wanted = requested != 0 && requested == generation;
        int active = atomic_load(&ring->actualRunning);
        if (wanted != active) {
            OSStatus code = output ? (wanted ? AudioOutputUnitStart(output) : AudioOutputUnitStop(output))
                                   : kAudioUnitErr_Uninitialized;
            atomic_store(&ring->error, code);
            if (!code) {
                if (!wanted) clearCaptureOnIdle = YES;
                atomic_store(&ring->actualRunning, wanted);
            }
            else if (wanted) atomic_compare_exchange_strong(&ring->requestedGeneration, &requested, 0);
        }
        if (++ticks % 50 == 0) {
            NSDictionary *report = @{
                @"route": route ?: @{}, @"generation": @(atomic_load(&ring->routeGeneration)),
                @"running": @(atomic_load(&ring->actualRunning)), @"error": @(atomic_load(&ring->error)),
                @"callbacks": @(atomic_load(&ring->callbacks)), @"audible_frames": @(atomic_load(&ring->audibleFrames)),
                @"underrun_frames": @(atomic_load(&ring->underrunFrames)),
                @"queued_frames": @(BWAudioQueued(atomic_load(&ring->writeFrame), atomic_load(&ring->readFrame))),
                @"input_frames": @(atomic_load(&ring->inputFrames)),
                @"input_nonzero_frames": @(atomic_load(&ring->inputNonzeroFrames)),
                @"input_delivered_frames": @(atomic_load(&ring->inputDeliveredFrames)),
                @"input_dropped_frames": @(atomic_load(&ring->inputDroppedFrames)),
                @"input_error": @(atomic_load(&ring->inputError))
            };
            [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
             writeToFile:status atomically:YES];
        }
    });
    dispatch_resume(audioTimer);
    return initial == noErr;
}
