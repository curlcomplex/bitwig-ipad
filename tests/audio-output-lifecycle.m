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
        int wanted=atomic_load(&r->requestedRunning),actual=atomic_load(&r->actualRunning);
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
int main(void){@autoreleasepool{
    AudioUnit handle=NULL;assert(AudioComponentInstanceNew(BW_COMPONENT,&handle)==noErr);
    BWOutput *unit=proxy(handle);BWAudioRing *r=calloc(1,sizeof(*r));r->bufferFrames=128;r->sampleRate=48000;r->channels=2;
    unit->ring=r;unit->callback.inputProc=silence;unit->format.mChannelsPerFrame=2;unit->format.mFormatFlags=kAudioFormatFlagIsNonInterleaved;
    atomic_store(&hostLive,true);pthread_t host;assert(pthread_create(&host,NULL,hostModel,r)==0);
    for(unsigned i=0;i<10;i++){
        assert(AudioOutputUnitStart(handle)==noErr);assert(atomic_load(&r->actualRunning)==1);
        assert(AudioOutputUnitStop(handle)==noErr);assert(atomic_load(&r->actualRunning)==0);
        assert(!unit->workerCreated); // Next iteration starts immediately.
    }
    assert(atomic_load(&startAcknowledgments)==10);assert(atomic_load(&stopAcknowledgments)==10);
    atomic_store(&hostLive,false);pthread_join(host,NULL);unit->ring=NULL;free(r);assert(AudioComponentInstanceDispose(handle)==noErr);
    puts("PASS: 10 immediate restart cycles waited for distinct start/stop acknowledgments and joined each worker");
}return 0;}
