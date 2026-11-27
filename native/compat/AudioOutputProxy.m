#import "LocalConfiguration.h"
#import <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <dlfcn.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include "../NativeAudioShared.h"
#define BW_COMPONENT ((AudioComponent)(uintptr_t)0x42574350)
#define BW_UNIT_MAGIC 0x4257554e
#define BW_DEVICE 0x42574456
typedef struct {
    uint32_t magic;AURenderCallbackStruct callback;AudioStreamBasicDescription format;
    AudioStreamBasicDescription inputFormat;
    SInt32 inputMap[BW_AUDIO_CHANNELS]; UInt32 inputMapCount, outputChannels, frames;
    BOOL inputEnabled, outputEnabled;
    uint64_t generation;
    BWAudioRing *ring;_Atomic bool running;pthread_t worker;BOOL workerCreated;double sampleTime;
} BWOutput;
static _Thread_local BWOutput *renderingUnit;
static NSMutableSet *units;
static NSLock *unitLock;
static void prepare(void){static dispatch_once_t once;dispatch_once(&once,^{units=[NSMutableSet new];unitLock=[NSLock new];});}
static BWOutput *proxy(AudioUnit unit){prepare();[unitLock lock];BOOL found=[units containsObject:[NSValue valueWithPointer:unit]];[unitLock unlock];return found?(BWOutput*)unit:NULL;}
static void *symbol(const char *name){static void *handle;static dispatch_once_t once;dispatch_once(&once,^{handle=dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",RTLD_NOW);});return dlsym(handle,name);}
static NSString *ringPath(void){NSURL *group=BWSharedContainerURL();return [[group URLByAppendingPathComponent:@"BitwigUser/Audio/ring.bin"] path];}
static void cancelRequest(BWOutput *unit) {
    uint64_t generation = unit->generation;
    atomic_compare_exchange_strong(&unit->ring->requestedGeneration, &generation, 0);
}
static void releaseProducer(BWOutput *unit) {
    uint64_t generation = unit->generation;
    atomic_store_explicit(&unit->ring->engineActivePID, 0, memory_order_relaxed);
    atomic_compare_exchange_strong_explicit(&unit->ring->engineActiveGeneration, &generation, 0,
                                           memory_order_release, memory_order_relaxed);
}
static BOOL routeMatches(const BWOutput *unit) {
    return atomic_load_explicit(&unit->ring->routeGeneration, memory_order_acquire) == unit->generation;
}
static void *produce(void *context){
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    if (getenv("BW_DSP_PROFILE")) pthread_setname_np("BWAudioProxy");
    BWOutput *unit=context;BWAudioRing *r=unit->ring;UInt32 frames=unit->frames,channels=unit->outputEnabled?unit->format.mChannelsPerFrame:0;
    BOOL planar=unit->format.mFormatFlags&kAudioFormatFlagIsNonInterleaved;
    AudioBufferList *list=calloc(1,offsetof(AudioBufferList,mBuffers)+MAX(channels,1)*sizeof(AudioBuffer));float *storage=calloc(frames*MAX(channels,1),sizeof(float));
    if (!list || !storage) {
        free(list); free(storage);
        atomic_store(&r->error, -108);
        atomic_store(&unit->running, false);
        releaseProducer(unit);
        return NULL;
    }
    list->mNumberBuffers=channels ? (planar?channels:1) : 0;
    for(UInt32 i=0;i<list->mNumberBuffers;i++){list->mBuffers[i].mNumberChannels=planar?1:channels;list->mBuffers[i].mDataByteSize=frames*sizeof(float)*(planar?1:channels);list->mBuffers[i].mData=storage+(planar?i*frames:0);}
    while (atomic_load(&unit->running) && routeMatches(unit)) {
        uint64_t write=atomic_load_explicit(&r->writeFrame,memory_order_relaxed),read=atomic_load_explicit(&r->readFrame,memory_order_acquire);
        uint64_t queued = BWAudioQueued(write, read);
        if (channels && (queued >= frames * 3 || queued + frames > BW_AUDIO_FRAMES)) { usleep(500); continue; }
        if (!channels && BWAudioQueued(atomic_load(&r->inputWriteFrame), atomic_load(&r->inputReadFrame)) < frames) {
            usleep(500);
            continue;
        }
        memset(storage,0,frames*channels*sizeof(float));AudioTimeStamp time={.mSampleTime=unit->sampleTime,.mHostTime=mach_absolute_time(),.mFlags=kAudioTimeStampSampleTimeValid|kAudioTimeStampHostTimeValid};AudioUnitRenderActionFlags flags=0;
        renderingUnit = unit;
        OSStatus result=unit->callback.inputProc(unit->callback.inputProcRefCon,&flags,&time,0,frames,list);
        renderingUnit = NULL;
        if(result){atomic_store(&r->error,result);atomic_store(&unit->running,false);break;}
        if (channels) {
            for (UInt32 frame = 0; frame < frames; frame++)
                for (UInt32 channel = 0; channel < unit->outputChannels; channel++)
                    r->samples[channel][(write+frame)%BW_AUDIO_FRAMES] =
                        channel >= channels ? 0 : planar ? ((float *)list->mBuffers[channel].mData)[frame]
                               : ((float *)list->mBuffers[0].mData)[frame*channels+channel];
            atomic_store_explicit(&r->writeFrame, write+frames, memory_order_release);
        }
        unit->sampleTime += frames;
    }
    free(storage);free(list);
    atomic_store(&unit->running, false);
    releaseProducer(unit);
    return NULL;
}
AudioComponent AudioComponentFindNext(AudioComponent previous,const AudioComponentDescription *description){if(description->componentType==kAudioUnitType_Output&&description->componentSubType=='ahal')return previous?NULL:BW_COMPONENT;return ((AudioComponent(*)(AudioComponent,const AudioComponentDescription*))symbol("AudioComponentFindNext"))(previous,description);}
OSStatus AudioComponentInstanceNew(AudioComponent component,AudioComponentInstance *instance){
    if(component!=BW_COMPONENT)return ((OSStatus(*)(AudioComponent,AudioComponentInstance*))symbol("AudioComponentInstanceNew"))(component,instance);
    prepare();BWOutput *unit=calloc(1,sizeof(*unit));if(!unit)return -108;unit->magic=BW_UNIT_MAGIC;unit->outputEnabled=YES;[unitLock lock];[units addObject:[NSValue valueWithPointer:unit]];[unitLock unlock];*instance=(AudioUnit)unit;fprintf(stdout,"[native audio] created foreground-output proxy\n");return noErr;
}
OSStatus AudioUnitSetProperty(AudioUnit handle,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,const void *data,UInt32 size){
    BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit,AudioUnitPropertyID,AudioUnitScope,AudioUnitElement,const void*,UInt32))symbol("AudioUnitSetProperty"))(handle,property,scope,element,data,size);
    if (atomic_load(&unit->running)) return kAudioUnitErr_Initialized;
    fprintf(stdout,"[native audio] proxy property=%u scope=%u element=%u size=%u\n",property,scope,element,size);
    if(property==kAudioOutputUnitProperty_CurrentDevice&&size==sizeof(UInt32))return *(UInt32*)data==BW_DEVICE?noErr:kAudioHardwareBadDeviceError;
    if (property == kAudioOutputUnitProperty_EnableIO && size == sizeof(UInt32)) {
        if (element == 1 && scope == kAudioUnitScope_Input) unit->inputEnabled = *(const UInt32 *)data != 0;
        else if (element == 0 && scope == kAudioUnitScope_Output) unit->outputEnabled = *(const UInt32 *)data != 0;
        else return kAudioUnitErr_InvalidElement;
        return noErr;
    }
    if (property == kAudioOutputUnitProperty_ChannelMap && scope == kAudioUnitScope_Output && element == 1) {
        if (size % sizeof(SInt32) || size / sizeof(SInt32) > BW_AUDIO_CHANNELS)
            return kAudioUnitErr_InvalidPropertyValue;
        UInt32 count = size / sizeof(SInt32);
        const SInt32 *map = data;
        for (UInt32 channel = 0; channel < count; channel++)
            if (map[channel] < -1 || map[channel] >= BW_AUDIO_CHANNELS) return kAudioUnitErr_InvalidPropertyValue;
        if (size) memcpy(unit->inputMap, map, size);
        unit->inputMapCount = count;
        return noErr;
    }
    if(property==kAudioUnitProperty_StreamFormat&&size==sizeof(AudioStreamBasicDescription)){
        AudioStreamBasicDescription format=*(AudioStreamBasicDescription*)data;
        if(format.mFormatID!=kAudioFormatLinearPCM||!(format.mFormatFlags&kAudioFormatFlagIsFloat)||format.mBitsPerChannel!=32||format.mChannelsPerFrame<1||format.mChannelsPerFrame>BW_AUDIO_CHANNELS)return kAudioUnitErr_FormatNotSupported;
        if (scope == kAudioUnitScope_Output && element == 1) unit->inputFormat = format;
        else if (scope == kAudioUnitScope_Input && element == 0) unit->format = format;
        else return kAudioUnitErr_InvalidElement;
        return noErr;
    }
    if(property==kAudioUnitProperty_SetRenderCallback&&size==sizeof(AURenderCallbackStruct)&&element==0){unit->callback=*(AURenderCallbackStruct*)data;return noErr;}
    if(property==kAudioUnitProperty_MaximumFramesPerSlice&&size==sizeof(UInt32))return *(UInt32*)data<=BW_AUDIO_FRAMES?noErr:kAudioUnitErr_TooManyFramesToProcess;
    return kAudioUnitErr_InvalidProperty;
}
OSStatus AudioUnitInitialize(AudioUnit handle){
    BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit))symbol("AudioUnitInitialize"))(handle);
    if (!unit->callback.inputProc || (!unit->inputEnabled && !unit->outputEnabled) ||
        (unit->outputEnabled && !unit->format.mChannelsPerFrame) ||
        (unit->inputEnabled && !unit->inputFormat.mChannelsPerFrame)) return kAudioUnitErr_Uninitialized;
    int fd=open(ringPath().fileSystemRepresentation,O_RDWR);if(fd<0)return kAudioUnitErr_FailedInitialization;
    struct stat status;
    BWAudioRing *r = fstat(fd, &status) || status.st_size < sizeof(BWAudioRing) ? MAP_FAILED :
        mmap(NULL,sizeof(BWAudioRing),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    close(fd);
    if(r==MAP_FAILED)return kAudioUnitErr_FailedInitialization;
    uint64_t generation = atomic_load_explicit(&r->routeGeneration, memory_order_acquire);
    BOOL valid = r->magic == BW_AUDIO_MAGIC && generation && !(generation & 1) && r->bufferFrames && r->bufferFrames <= 4096;
    if (unit->outputEnabled)
        valid &= fabs(unit->format.mSampleRate-r->sampleRate) <= 1 && unit->format.mChannelsPerFrame <= r->channels;
    if (unit->inputEnabled) {
        valid &= r->inputChannels > 0 && fabs(unit->inputFormat.mSampleRate-r->sampleRate) <= 1;
        UInt32 channels = unit->inputFormat.mChannelsPerFrame;
        valid &= unit->inputMapCount ? unit->inputMapCount == channels : channels <= r->inputChannels;
        for (UInt32 channel = 0; channel < unit->inputMapCount; channel++)
            if (unit->inputMap[channel] >= (SInt32)r->inputChannels) valid = NO;
    }
    unit->generation = generation;
    unit->outputChannels = r->channels;
    unit->frames = r->bufferFrames;
    if (!valid || atomic_load_explicit(&r->routeGeneration, memory_order_acquire) != generation) {
        munmap(r, sizeof(*r));
        return kAudioUnitErr_FormatNotSupported;
    }
    unit->ring = r;
    fprintf(stdout, "[native audio] proxy initialized rate=%.0f input=%u output=%u frames=%u\n",
            r->sampleRate, unit->inputFormat.mChannelsPerFrame, unit->format.mChannelsPerFrame, unit->frames);
    return noErr;
}
OSStatus AudioOutputUnitStart(AudioUnit handle){
    BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit))symbol("AudioOutputUnitStart"))(handle);if(!unit->ring)return kAudioUnitErr_Uninitialized;if(!routeMatches(unit))return kAudioHardwareBadDeviceError;if(atomic_load(&unit->running))return noErr;
    if(unit->workerCreated){pthread_join(unit->worker,NULL);unit->workerCreated=NO;}
    // The host owns RemoteIO and processes requests asynchronously. Do not
    // reset its read cursor or overwrite an unacknowledged stop with a start.
    cancelRequest(unit);
    for(int i=0;i<5000&&atomic_load(&unit->ring->actualRunning);i++)usleep(1000);
    if (atomic_load(&unit->ring->actualRunning) || !routeMatches(unit)) return kAudioUnitErr_FailedInitialization;
    uint64_t inactive = 0;
    if (!atomic_compare_exchange_strong(&unit->ring->engineActiveGeneration, &inactive, unit->generation))
        return kAudioUnitErr_CannotDoInCurrentContext;
    atomic_store_explicit(&unit->ring->engineActivePID, getpid(), memory_order_release);
    if (!routeMatches(unit)) {
        releaseProducer(unit);
        return kAudioHardwareBadDeviceError;
    }
    // A stopped unit must not replay queued frames from its preceding run.
    atomic_store(&unit->ring->readFrame, atomic_load(&unit->ring->writeFrame));
    atomic_store(&unit->ring->inputReadFrame, atomic_load(&unit->ring->inputWriteFrame));
    atomic_store(&unit->ring->error, 0);
    atomic_store(&unit->running, true);
    if (pthread_create(&unit->worker, NULL, produce, unit)) {
        atomic_store(&unit->running, false);
        releaseProducer(unit);
        return kAudioUnitErr_FailedInitialization;
    }
    unit->workerCreated=YES;
    // RemoteIO can call back immediately. Prepare its first buffer before
    // requesting start rather than racing the new producer thread.
    for(int i=0;unit->outputEnabled&&i<1000&&atomic_load(&unit->running);i++){
        if(atomic_load(&unit->ring->writeFrame)-atomic_load(&unit->ring->readFrame)>=unit->frames)break;
        usleep(1000);
    }
    OSStatus result=atomic_load(&unit->ring->error);
    if(result||!atomic_load(&unit->running)||(unit->outputEnabled && atomic_load(&unit->ring->writeFrame)-atomic_load(&unit->ring->readFrame)<unit->frames)){
        atomic_store(&unit->running,false);pthread_join(unit->worker,NULL);unit->workerCreated=NO;
        return result?:kAudioUnitErr_FailedInitialization;
    }
    inactive = 0;
    BOOL requested = routeMatches(unit) &&
        atomic_compare_exchange_strong(&unit->ring->requestedGeneration, &inactive, unit->generation);
    for(int i=0;requested && i<5000 && routeMatches(unit);i++){result=atomic_load(&unit->ring->error);if(result)break;if(atomic_load(&unit->ring->actualRunning)){fprintf(stdout,"[native audio] foreground RemoteIO acknowledged start\n");return noErr;}usleep(1000);}
    cancelRequest(unit);atomic_store(&unit->running,false);pthread_join(unit->worker,NULL);unit->workerCreated=NO;
    return result?:kAudioUnitErr_FailedInitialization;
}
OSStatus AudioOutputUnitStop(AudioUnit handle){
    BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit))symbol("AudioOutputUnitStop"))(handle);
    atomic_store(&unit->running,false);
    if(unit->workerCreated){pthread_join(unit->worker,NULL);unit->workerCreated=NO;}
    if(unit->ring && routeMatches(unit))cancelRequest(unit);
    if(unit->ring && routeMatches(unit)){
        for(int i=0;i<5000&&atomic_load(&unit->ring->actualRunning);i++)usleep(1000);
        if(atomic_load(&unit->ring->actualRunning))return kAudioUnitErr_CannotDoInCurrentContext;
    }
    return noErr;
}
OSStatus AudioUnitUninitialize(AudioUnit handle){BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit))symbol("AudioUnitUninitialize"))(handle);AudioOutputUnitStop(handle);if(unit->ring){munmap(unit->ring,sizeof(*unit->ring));unit->ring=NULL;}return noErr;}
OSStatus AudioComponentInstanceDispose(AudioComponentInstance handle){BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioComponentInstance))symbol("AudioComponentInstanceDispose"))(handle);AudioUnitUninitialize(handle);[unitLock lock];[units removeObject:[NSValue valueWithPointer:unit]];[unitLock unlock];free(unit);return noErr;}
OSStatus AudioUnitRender(AudioUnit handle, AudioUnitRenderActionFlags *flags,
                         const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    BWOutput *unit = (AudioUnit)renderingUnit == handle ? renderingUnit : proxy(handle);
    if (!unit) return ((OSStatus(*)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32,AudioBufferList*))symbol("AudioUnitRender"))(handle,flags,time,bus,frames,data);
    if (bus != 1 || !unit->inputEnabled) return kAudioUnitErr_InvalidElement;
    BWAudioRing *r = unit->ring;
    if (!r) return kAudioUnitErr_Uninitialized;
    UInt32 channels = unit->inputFormat.mChannelsPerFrame;
    BOOL planar = unit->inputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved;
    if (data->mNumberBuffers != (planar ? channels : 1)) return kAudioUnitErr_InvalidPropertyValue;
    UInt32 bytes = frames * sizeof(float) * (planar ? 1 : channels);
    for (UInt32 buffer = 0; buffer < data->mNumberBuffers; buffer++) {
        if (!data->mBuffers[buffer].mData || data->mBuffers[buffer].mDataByteSize < bytes)
            return kAudioUnitErr_InvalidPropertyValue;
    }
    uint64_t read = atomic_load_explicit(&r->inputReadFrame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&r->inputWriteFrame, memory_order_acquire);
    UInt32 count = routeMatches(unit) ? (UInt32)MIN((uint64_t)frames, BWAudioQueued(write, read)) : 0;
    BOOL signal = NO;
    for (UInt32 channel = 0; channel < channels; channel++) {
        SInt32 source = unit->inputMapCount ? unit->inputMap[channel] : (SInt32)channel;
        float *buffer = data->mBuffers[planar ? channel : 0].mData;
        for (UInt32 frame = 0; frame < frames; frame++) {
            float value = frame < count && source >= 0 ? r->inputSamples[source][(read+frame)%BW_AUDIO_FRAMES] : 0;
            buffer[planar ? frame : frame*channels+channel] = value;
            signal |= value != 0;
        }
    }
    if (count) atomic_store_explicit(&r->inputReadFrame, read + count, memory_order_release);
    atomic_fetch_add(&r->inputDeliveredFrames, count);
    if (flags) {
        if (signal) *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        else *flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    return noErr;
}
