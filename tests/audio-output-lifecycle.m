// Exercise the production proxy against a delayed foreground-host model.
// This checks its cross-process handshake, not iPad audio fidelity.
#import "../native/compat/AudioOutputProxy.m"
#include <assert.h>
static _Atomic bool hostLive;
static _Atomic unsigned startAcknowledgments,stopAcknowledgments;
static OSStatus silence(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *buffers){return noErr;}
static void *hostModel(void *context){
    BWAudioRing *r=context;
    while(atomic_load(&hostLive)){
        int wanted=atomic_load(&r->requestedGeneration)==2,actual=atomic_load(&r->actualRunning);
        if(wanted!=actual){
            usleep(40000); // Match an asynchronous host that has not handled stop yet.
            atomic_store(&r->actualRunning,wanted);
            if(wanted)atomic_fetch_add(&startAcknowledgments,1);else atomic_fetch_add(&stopAcknowledgments,1);
        }
        if(atomic_load(&r->actualRunning))atomic_store(&r->readFrame,atomic_load(&r->writeFrame));
        usleep(1000);
    }
    return NULL;
}
static void testInput(AudioUnit handle, BWOutput *unit) {
    BWAudioRing *r = unit->ring;
    unit->inputEnabled = YES;
    unit->inputFormat.mChannelsPerFrame = 2;
    unit->inputFormat.mFormatFlags = kAudioFormatFlagIsNonInterleaved;
    SInt32 map[] = {1, -1};
    assert(AudioUnitSetProperty(handle, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, map, sizeof(map)) == noErr);
    struct { UInt32 count; AudioBuffer buffers[2]; } planar = {2, {{1, 16, NULL}, {1, 16, NULL}}};
    float first[4] = {9, 9, 9, 9}, second[4] = {9, 9, 9, 9};
    planar.buffers[0].mData = first;
    planar.buffers[1].mData = second;
    for (UInt32 i = 0; i < 2; i++) r->inputSamples[1][(BW_AUDIO_FRAMES - 1 + i) % BW_AUDIO_FRAMES] = i + 1;
    atomic_store(&r->inputReadFrame, BW_AUDIO_FRAMES - 1);
    atomic_store(&r->inputWriteFrame, BW_AUDIO_FRAMES + 1);
    AudioTimeStamp time = {0};
    AudioUnitRenderActionFlags flags = kAudioUnitRenderAction_OutputIsSilence;
    renderingUnit = unit;
    assert(AudioUnitRender(handle, &flags, &time, 1, 4, (AudioBufferList *)&planar) == noErr);
    assert(!(flags & kAudioUnitRenderAction_OutputIsSilence));
    assert(first[0] == 1 && first[1] == 2 && first[2] == 0 && first[3] == 0);
    for (int i = 0; i < 4; i++) assert(second[i] == 0);
    assert(atomic_load(&r->inputDeliveredFrames) == 2);
    assert(AudioUnitRender(handle, &flags, &time, 1, 4, (AudioBufferList *)&planar) == noErr);
    assert(flags & kAudioUnitRenderAction_OutputIsSilence);
    // A changed route cannot expose old capture frames to the previous engine unit.
    atomic_store(&r->inputWriteFrame, BW_AUDIO_FRAMES + 3);
    atomic_store(&r->routeGeneration, 4);
    assert(AudioUnitRender(handle, &flags, &time, 1, 4, (AudioBufferList *)&planar) == noErr);
    assert(flags & kAudioUnitRenderAction_OutputIsSilence);
    assert(atomic_load(&r->inputDeliveredFrames) == 2);
    renderingUnit = NULL;
    puts("PASS: wrapped input, channel map/silence, underrun padding and stale route");
}
int main(void){@autoreleasepool{
    AudioUnit handle=NULL;assert(AudioComponentInstanceNew(BW_COMPONENT,&handle)==noErr);
    BWOutput *unit=proxy(handle);BWAudioRing *r=calloc(1,sizeof(*r));r->bufferFrames=128;r->sampleRate=48000;r->channels=2;
    atomic_store(&r->routeGeneration, 2);
    unit->ring=r;unit->generation=2;unit->frames=128;unit->outputChannels=2;unit->callback.inputProc=silence;unit->format.mChannelsPerFrame=2;unit->format.mFormatFlags=kAudioFormatFlagIsNonInterleaved;
    atomic_store(&hostLive,true);pthread_t host;assert(pthread_create(&host,NULL,hostModel,r)==0);
    for(unsigned i=0;i<10;i++){
        assert(AudioOutputUnitStart(handle)==noErr);assert(atomic_load(&r->actualRunning)==1);
        assert(AudioOutputUnitStop(handle)==noErr);assert(atomic_load(&r->actualRunning)==0);
        assert(!unit->workerCreated); // Next iteration starts immediately.
    }
    assert(atomic_load(&startAcknowledgments)==10);assert(atomic_load(&stopAcknowledgments)==10);
    atomic_store(&hostLive,false);pthread_join(host,NULL);testInput(handle,unit);unit->ring=NULL;free(r);assert(AudioComponentInstanceDispose(handle)==noErr);
    puts("PASS: 10 immediate restart cycles waited for distinct start/stop acknowledgments and joined each worker");
}return 0;}
