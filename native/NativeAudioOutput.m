#import "compat/LocalConfiguration.h"
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include "NativeAudioShared.h"
static BWAudioRing *ring;
static AudioUnit output;
static dispatch_source_t audioTimer;
void BWStopAudioOutput(void){if(ring)atomic_store(&ring->requestedRunning,0);}
static OSStatus render(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *buffers){
    BWAudioRing *r=context;uint64_t read=atomic_load_explicit(&r->readFrame,memory_order_relaxed),write=atomic_load_explicit(&r->writeFrame,memory_order_acquire);
    UInt32 count=(UInt32)MIN((uint64_t)frames,write-read);uint64_t audible=0;
    for(UInt32 i=0;i<frames;i++){
        float left=0,right=0;
        if(i<count){UInt32 index=(UInt32)((read+i)%BW_AUDIO_FRAMES)*BW_AUDIO_CHANNELS;left=r->samples[index];right=r->samples[index+1];if(left!=0||right!=0)audible++;}
        if(buffers->mNumberBuffers==1&&buffers->mBuffers[0].mNumberChannels==2){float *p=buffers->mBuffers[0].mData;p[2*i]=left;p[2*i+1]=right;}
        else for(UInt32 channel=0;channel<buffers->mNumberBuffers;channel++)((float*)buffers->mBuffers[channel].mData)[i]=channel?right:left;
    }
    atomic_store_explicit(&r->readFrame,read+count,memory_order_release);
    atomic_fetch_add(&r->callbacks,1);atomic_fetch_add(&r->audibleFrames,audible);atomic_fetch_add(&r->underrunFrames,frames-count);return noErr;
}
BOOL BWPrepareAudioOutput(void){
    if(ring){atomic_store(&ring->requestedRunning,0);if(output)AudioOutputUnitStop(output);atomic_store(&ring->actualRunning,0);atomic_store(&ring->readFrame,0);atomic_store(&ring->writeFrame,0);atomic_store(&ring->error,0);return YES;}
    AVAudioSession *session=AVAudioSession.sharedInstance;NSError *error=nil;
    if(![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error]||![session setActive:YES error:&error]){NSLog(@"Native output session failed: %@",error);return NO;}
    NSURL *group=BWSharedContainerURL();
    NSURL *directory=[group URLByAppendingPathComponent:@"BitwigUser/Audio" isDirectory:YES];
    if(![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error])return NO;
    int fd=open([[directory URLByAppendingPathComponent:@"ring.bin"] fileSystemRepresentation],O_CREAT|O_RDWR,0600);if(fd<0)return NO;
    if(ftruncate(fd,sizeof(BWAudioRing))){close(fd);return NO;}
    BWAudioRing *memory=mmap(NULL,sizeof(BWAudioRing),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);close(fd);if(memory==MAP_FAILED)return NO;
    memset(memory,0,sizeof(*memory));memory->magic=BW_AUDIO_MAGIC;memory->channels=MIN(BW_AUDIO_CHANNELS,(uint32_t)session.outputNumberOfChannels);memory->sampleRate=session.sampleRate;memory->bufferFrames=(uint32_t)llround(session.IOBufferDuration*session.sampleRate);memory->outputLatency=session.outputLatency;
    AVAudioSessionPortDescription *port=session.currentRoute.outputs.firstObject;
    NSDictionary *route=@{@"name":port.portName?:@"iPad audio",@"uid":port.UID?:@"",@"type":port.portType?:@"",@"rate":@(memory->sampleRate),@"channels":@(memory->channels),@"frames":@(memory->bufferFrames),@"latency":@(memory->outputLatency)};
    [[NSJSONSerialization dataWithJSONObject:route options:0 error:nil] writeToURL:[directory URLByAppendingPathComponent:@"route.json"] atomically:YES];
    AudioComponentDescription description={.componentType=kAudioUnitType_Output,.componentSubType=kAudioUnitSubType_RemoteIO,.componentManufacturer=kAudioUnitManufacturer_Apple};
    AudioComponent component=AudioComponentFindNext(NULL,&description);OSStatus result=component?AudioComponentInstanceNew(component,&output):-1;
    AudioStreamBasicDescription format={.mSampleRate=memory->sampleRate,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved,.mBytesPerPacket=4,.mFramesPerPacket=1,.mBytesPerFrame=4,.mChannelsPerFrame=memory->channels,.mBitsPerChannel=32};
    AURenderCallbackStruct callback={render,memory};
    if(!result)result=AudioUnitSetProperty(output,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&format,sizeof(format));
    if(!result)result=AudioUnitSetProperty(output,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback));
    if(!result)result=AudioUnitInitialize(output);
    if(result){NSLog(@"Native output initialization failed: %d",(int)result);if(output){AudioComponentInstanceDispose(output);output=NULL;}munmap(memory,sizeof(*memory));return NO;}
    ring=memory;NSLog(@"Native foreground output ready: %@",route);
    NSString *status=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"native-audio.json"];
    audioTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(audioTimer,DISPATCH_TIME_NOW,20*NSEC_PER_MSEC,2*NSEC_PER_MSEC);
    __block NSUInteger ticks=0;
    dispatch_source_set_event_handler(audioTimer,^{
        int wanted=atomic_load(&ring->requestedRunning),active=atomic_load(&ring->actualRunning);
        if(wanted!=active){OSStatus code=wanted?AudioOutputUnitStart(output):AudioOutputUnitStop(output);atomic_store(&ring->error,code);if(!code)atomic_store(&ring->actualRunning,wanted);else atomic_store(&ring->requestedRunning,active);NSLog(@"Native output running=%d status=%d",wanted,(int)code);}
        if(++ticks%50==0){NSDictionary *report=@{@"route":route,@"running":@(atomic_load(&ring->actualRunning)),@"error":@(atomic_load(&ring->error)),@"callbacks":@(atomic_load(&ring->callbacks)),@"audible_frames":@(atomic_load(&ring->audibleFrames)),@"underrun_frames":@(atomic_load(&ring->underrunFrames)),@"queued_frames":@(atomic_load(&ring->writeFrame)-atomic_load(&ring->readFrame))};[[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:status atomically:YES];}
    });dispatch_resume(audioTimer);return YES;
}
