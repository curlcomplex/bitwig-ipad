#import <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <dlfcn.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include "../NativeAudioShared.h"
#define BW_COMPONENT ((AudioComponent)(uintptr_t)0x42574350)
#define BW_UNIT_MAGIC 0x4257554e
#define BW_DEVICE 0x42574456
typedef struct {
    uint32_t magic;AURenderCallbackStruct callback;AudioStreamBasicDescription format;
    BWAudioRing *ring;_Atomic bool running;pthread_t worker;BOOL workerCreated;double sampleTime;
} BWOutput;
static NSMutableSet *units;
static NSLock *unitLock;
static void prepare(void){static dispatch_once_t once;dispatch_once(&once,^{units=[NSMutableSet new];unitLock=[NSLock new];});}
static BWOutput *proxy(AudioUnit unit){prepare();[unitLock lock];BOOL found=[units containsObject:[NSValue valueWithPointer:unit]];[unitLock unlock];return found?(BWOutput*)unit:NULL;}
static void *symbol(const char *name){static void *handle;static dispatch_once_t once;dispatch_once(&once,^{handle=dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",RTLD_NOW);});return dlsym(handle,name);}
static NSString *ringPath(void){NSURL *group=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.felixgodden.bitwigipad"];return [[group URLByAppendingPathComponent:@"BitwigUser/Audio/ring.bin"] path];}
static void *produce(void *context){
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    BWOutput *unit=context;BWAudioRing *r=unit->ring;UInt32 frames=MAX(32,MIN(r->bufferFrames,4096)),channels=unit->format.mChannelsPerFrame;
    BOOL planar=unit->format.mFormatFlags&kAudioFormatFlagIsNonInterleaved;
    AudioBufferList *list=calloc(1,offsetof(AudioBufferList,mBuffers)+MAX(channels,1)*sizeof(AudioBuffer));float *storage=calloc(frames*MAX(channels,1),sizeof(float));
    list->mNumberBuffers=planar?channels:1;
    for(UInt32 i=0;i<list->mNumberBuffers;i++){list->mBuffers[i].mNumberChannels=planar?1:channels;list->mBuffers[i].mDataByteSize=frames*sizeof(float)*(planar?1:channels);list->mBuffers[i].mData=storage+(planar?i*frames:0);}
    while(atomic_load(&unit->running)){
        uint64_t write=atomic_load_explicit(&r->writeFrame,memory_order_relaxed),read=atomic_load_explicit(&r->readFrame,memory_order_acquire);
        if(write-read>=frames*3||write-read+frames>BW_AUDIO_FRAMES){usleep(500);continue;}
        memset(storage,0,frames*channels*sizeof(float));AudioTimeStamp time={.mSampleTime=unit->sampleTime,.mHostTime=mach_absolute_time(),.mFlags=kAudioTimeStampSampleTimeValid|kAudioTimeStampHostTimeValid};AudioUnitRenderActionFlags flags=0;
        OSStatus result=unit->callback.inputProc(unit->callback.inputProcRefCon,&flags,&time,0,frames,list);
        if(result){atomic_store(&r->error,result);atomic_store(&unit->running,false);break;}
        for(UInt32 frame=0;frame<frames;frame++){UInt32 offset=(UInt32)((write+frame)%BW_AUDIO_FRAMES)*BW_AUDIO_CHANNELS;for(UInt32 channel=0;channel<BW_AUDIO_CHANNELS;channel++)r->samples[offset+channel]=channel<channels?(planar?((float*)list->mBuffers[channel].mData)[frame]:((float*)list->mBuffers[0].mData)[frame*channels+channel]):0;}
        unit->sampleTime+=frames;atomic_store_explicit(&r->writeFrame,write+frames,memory_order_release);
    }
    free(storage);free(list);return NULL;
}
AudioComponent AudioComponentFindNext(AudioComponent previous,const AudioComponentDescription *description){if(description->componentType==kAudioUnitType_Output&&description->componentSubType=='ahal')return previous?NULL:BW_COMPONENT;return ((AudioComponent(*)(AudioComponent,const AudioComponentDescription*))symbol("AudioComponentFindNext"))(previous,description);}
OSStatus AudioComponentInstanceNew(AudioComponent component,AudioComponentInstance *instance){
    if(component!=BW_COMPONENT)return ((OSStatus(*)(AudioComponent,AudioComponentInstance*))symbol("AudioComponentInstanceNew"))(component,instance);
    prepare();BWOutput *unit=calloc(1,sizeof(*unit));if(!unit)return -108;unit->magic=BW_UNIT_MAGIC;[unitLock lock];[units addObject:[NSValue valueWithPointer:unit]];[unitLock unlock];*instance=(AudioUnit)unit;fprintf(stdout,"[native audio] created foreground-output proxy\n");return noErr;
}
OSStatus AudioUnitSetProperty(AudioUnit handle,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,const void *data,UInt32 size){
    BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit,AudioUnitPropertyID,AudioUnitScope,AudioUnitElement,const void*,UInt32))symbol("AudioUnitSetProperty"))(handle,property,scope,element,data,size);
    fprintf(stdout,"[native audio] proxy property=%u scope=%u element=%u size=%u\n",property,scope,element,size);
    if(property==kAudioOutputUnitProperty_CurrentDevice&&size==sizeof(UInt32))return *(UInt32*)data==BW_DEVICE?noErr:kAudioHardwareBadDeviceError;
    if(property==kAudioOutputUnitProperty_EnableIO&&size==sizeof(UInt32))return element==1&&*(UInt32*)data?kAudioUnitErr_InvalidElement:noErr;
    if(property==kAudioUnitProperty_StreamFormat&&size==sizeof(AudioStreamBasicDescription)){
        AudioStreamBasicDescription format=*(AudioStreamBasicDescription*)data;
        if(format.mFormatID!=kAudioFormatLinearPCM||!(format.mFormatFlags&kAudioFormatFlagIsFloat)||format.mBitsPerChannel!=32||format.mChannelsPerFrame<1||format.mChannelsPerFrame>BW_AUDIO_CHANNELS)return kAudioUnitErr_FormatNotSupported;
        unit->format=format;return noErr;
    }
    if(property==kAudioUnitProperty_SetRenderCallback&&size==sizeof(AURenderCallbackStruct)&&element==0){unit->callback=*(AURenderCallbackStruct*)data;return noErr;}
    if(property==kAudioUnitProperty_MaximumFramesPerSlice&&size==sizeof(UInt32))return *(UInt32*)data<=BW_AUDIO_FRAMES?noErr:kAudioUnitErr_TooManyFramesToProcess;
    return kAudioUnitErr_InvalidProperty;
}
OSStatus AudioUnitInitialize(AudioUnit handle){
    BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit))symbol("AudioUnitInitialize"))(handle);
    if(!unit->callback.inputProc||!unit->format.mChannelsPerFrame)return kAudioUnitErr_Uninitialized;
    int fd=open(ringPath().fileSystemRepresentation,O_RDWR);if(fd<0)return kAudioUnitErr_FailedInitialization;
    BWAudioRing *r=mmap(NULL,sizeof(BWAudioRing),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);close(fd);
    if(r==MAP_FAILED)return kAudioUnitErr_FailedInitialization;
    if(r->magic!=BW_AUDIO_MAGIC||fabs(unit->format.mSampleRate-r->sampleRate)>1){munmap(r,sizeof(*r));return kAudioUnitErr_FormatNotSupported;}
    unit->ring=r;fprintf(stdout,"[native audio] proxy initialized rate=%.0f channels=%u frames=%u\n",r->sampleRate,unit->format.mChannelsPerFrame,r->bufferFrames);return noErr;
}
OSStatus AudioOutputUnitStart(AudioUnit handle){
    BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit))symbol("AudioOutputUnitStart"))(handle);if(!unit->ring)return kAudioUnitErr_Uninitialized;if(atomic_load(&unit->running))return noErr;
    if(unit->workerCreated){pthread_join(unit->worker,NULL);unit->workerCreated=NO;}
    // The host owns RemoteIO and processes requests asynchronously. Do not
    // reset its read cursor or overwrite an unacknowledged stop with a start.
    atomic_store(&unit->ring->requestedRunning,0);
    for(int i=0;i<5000&&atomic_load(&unit->ring->actualRunning);i++)usleep(1000);
    if(atomic_load(&unit->ring->actualRunning))return kAudioUnitErr_FailedInitialization;
    // A stopped unit must not replay queued frames from its preceding run.
    atomic_store(&unit->ring->readFrame,atomic_load(&unit->ring->writeFrame));
    atomic_store(&unit->ring->error,0);
    atomic_store(&unit->running,true);if(pthread_create(&unit->worker,NULL,produce,unit)){atomic_store(&unit->running,false);return kAudioUnitErr_FailedInitialization;}
    unit->workerCreated=YES;
    // RemoteIO can call back immediately. Prepare its first buffer before
    // requesting start rather than racing the new producer thread.
    for(int i=0;i<1000&&atomic_load(&unit->running);i++){
        if(atomic_load(&unit->ring->writeFrame)-atomic_load(&unit->ring->readFrame)>=unit->ring->bufferFrames)break;
        usleep(1000);
    }
    OSStatus result=atomic_load(&unit->ring->error);
    if(result||!atomic_load(&unit->running)||atomic_load(&unit->ring->writeFrame)-atomic_load(&unit->ring->readFrame)<unit->ring->bufferFrames){
        atomic_store(&unit->running,false);pthread_join(unit->worker,NULL);unit->workerCreated=NO;
        return result?:kAudioUnitErr_FailedInitialization;
    }
    atomic_store(&unit->ring->requestedRunning,1);
    for(int i=0;i<5000;i++){result=atomic_load(&unit->ring->error);if(result)break;if(atomic_load(&unit->ring->actualRunning)){fprintf(stdout,"[native audio] foreground RemoteIO acknowledged start\n");return noErr;}usleep(1000);}
    atomic_store(&unit->ring->requestedRunning,0);atomic_store(&unit->running,false);pthread_join(unit->worker,NULL);unit->workerCreated=NO;
    return result?:kAudioUnitErr_FailedInitialization;
}
OSStatus AudioOutputUnitStop(AudioUnit handle){
    BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit))symbol("AudioOutputUnitStop"))(handle);
    if(unit->ring)atomic_store(&unit->ring->requestedRunning,0);
    atomic_store(&unit->running,false);
    if(unit->workerCreated){pthread_join(unit->worker,NULL);unit->workerCreated=NO;}
    if(unit->ring){
        for(int i=0;i<5000&&atomic_load(&unit->ring->actualRunning);i++)usleep(1000);
        if(atomic_load(&unit->ring->actualRunning))return kAudioUnitErr_CannotDoInCurrentContext;
    }
    return noErr;
}
OSStatus AudioUnitUninitialize(AudioUnit handle){BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioUnit))symbol("AudioUnitUninitialize"))(handle);AudioOutputUnitStop(handle);if(unit->ring){munmap(unit->ring,sizeof(*unit->ring));unit->ring=NULL;}return noErr;}
OSStatus AudioComponentInstanceDispose(AudioComponentInstance handle){BWOutput *unit=proxy(handle);if(!unit)return ((OSStatus(*)(AudioComponentInstance))symbol("AudioComponentInstanceDispose"))(handle);AudioUnitUninitialize(handle);[unitLock lock];[units removeObject:[NSValue valueWithPointer:unit]];[unitLock unlock];free(unit);return noErr;}
OSStatus AudioUnitRender(AudioUnit handle,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *data){if(proxy(handle))return kAudioUnitErr_InvalidElement;return ((OSStatus(*)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32,AudioBufferList*))symbol("AudioUnitRender"))(handle,flags,time,bus,frames,data);}
