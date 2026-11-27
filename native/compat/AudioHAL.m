#import "LocalConfiguration.h"
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include "../NativeAudioShared.h"

// Desktop HAL handles describing AVAudioSession's actual current output route.
enum { BWSystem=1,BWPlugin=0x4257504c,BWDevice=0x42574456,BWStream=0x42575354,BWInputStream=0x4257494e };
static BWAudioRing *sharedAudio;
static NSLock *routeLock;
static NSURL *routeFile;
static uint64_t cachedGeneration;
static _Thread_local struct {
    UInt32 scope, size;
    uint64_t generation;
} directionalStreamQuery;
@interface BWAudioRoute:NSObject
@property NSDictionary *info;
@end
@implementation BWAudioRoute
- (double)sampleRate{return [self.info[@"rate"] doubleValue];}
- (NSInteger)outputNumberOfChannels{return [self.info[@"channels"] integerValue];}
- (double)IOBufferDuration{return [self.info[@"frames"] doubleValue]/self.sampleRate;}
- (double)outputLatency{return [self.info[@"latency"] doubleValue];}
- (double)inputLatency{return [self.info[@"input_latency"] doubleValue];}
- (NSInteger)inputNumberOfChannels{return [self.info[@"input_channels"] integerValue];}
- (id)currentRoute{return self;}
- (NSArray*)outputs{return self.outputNumberOfChannels?@[self]:@[];}
- (NSString*)portName{return self.info[@"name"];}
- (NSString*)UID{return self.info[@"uid"];}
- (NSString*)portType{return self.info[@"type"];}
- (BOOL)setPreferredSampleRate:(double)value error:(NSError**)error{return fabs(value-self.sampleRate)<1;}
- (BOOL)setPreferredIOBufferDuration:(double)value error:(NSError**)error{return fabs(value-self.IOBufferDuration)<1/self.sampleRate;}
@end
static uint64_t routeGeneration(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        routeLock = [NSLock new];
        NSURL *directory = [BWSharedContainerURL() URLByAppendingPathComponent:@"BitwigUser/Audio"];
        routeFile = [directory URLByAppendingPathComponent:@"route.json"];
        int fd = open([[directory URLByAppendingPathComponent:@"ring.bin"] fileSystemRepresentation], O_RDONLY);
        if (fd >= 0) {
            struct stat status;
            if (!fstat(fd, &status) && status.st_size >= sizeof(BWAudioRing)) {
                void *memory = mmap(NULL, sizeof(BWAudioRing), PROT_READ, MAP_SHARED, fd, 0);
                if (memory != MAP_FAILED) {
                    BWAudioRing *mapped = memory;
                    if (mapped->magic == BW_AUDIO_MAGIC) sharedAudio = mapped;
                    else munmap(memory, sizeof(BWAudioRing));
                }
            }
            close(fd);
        }
    });
    return sharedAudio ? atomic_load_explicit(&sharedAudio->routeGeneration, memory_order_acquire) : 0;
}

static BWAudioRoute *session(void) {
    static BWAudioRoute *audio;
    uint64_t generation = routeGeneration();
    [routeLock lock];
    if (!audio || (generation && !(generation & 1) && generation != cachedGeneration)) {
        NSData *data = [NSData dataWithContentsOfURL:routeFile];
        NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (info && generation && !(generation & 1) && [info[@"generation"] unsignedLongLongValue] == generation &&
            generation == routeGeneration()) {
            BWAudioRoute *updated = [BWAudioRoute new];
            updated.info = info;
            audio = updated;
            cachedGeneration = generation;
        }
    }
    BWAudioRoute *snapshot = audio;
    [routeLock unlock];
    return snapshot;
}
static NSData *bytes(const void *value,NSUInteger size){return [NSData dataWithBytes:value length:size];}
static NSData *u32(UInt32 value){return bytes(&value,sizeof(value));}
static NSData *f64(Float64 value){return bytes(&value,sizeof(value));}
static NSData *string(NSString *value,BOOL retain){CFStringRef ref=(__bridge CFStringRef)value;if(retain)CFRetain(ref);return bytes(&ref,sizeof(ref));}
static BOOL ours(AudioObjectID object){return object==BWSystem||object==BWPlugin||object==BWDevice||object==BWStream||object==BWInputStream;}
static NSData *property(AudioObjectID object,const AudioObjectPropertyAddress *address,UInt32 qualifierSize,const void *qualifier,BOOL retain) {
    BWAudioRoute *audio=session();if(!audio||!ours(object))return nil;
    UInt32 selector=address->mSelector;BOOL input=object==BWInputStream || address->mScope==kAudioObjectPropertyScopeInput;
    UInt32 channels=input?(UInt32)audio.inputNumberOfChannels:(UInt32)audio.outputNumberOfChannels;
    BWAudioRoute *route=audio;
    BOOL available = audio.outputNumberOfChannels > 0 || audio.inputNumberOfChannels > 0;
    if(selector==kAudioObjectPropertyClass)return u32(object==BWSystem?'asys':object==BWPlugin?'aplg':object==BWDevice?'adev':'astr');
    if(selector==kAudioObjectPropertyBaseClass)return u32(kAudioObjectClassID);
    if(selector==kAudioObjectPropertyOwner)return u32(object==BWDevice?BWPlugin:(object==BWStream||object==BWInputStream)?BWDevice:object==BWPlugin?BWSystem:0);
    if(selector==kAudioObjectPropertyManufacturer)return string(@"iPadOS audio",retain);
    if(selector==kAudioObjectPropertyName)return string(object==BWDevice?(route.portName?:@"iPad audio"):@"Bitwig iPad audio adapter",retain);
    if (selector == kAudioObjectPropertyOwnedObjects) {
        if (object == BWSystem) return u32(BWPlugin);
        if (object == BWPlugin && available) return u32(BWDevice);
        if (object == BWDevice) {
            UInt32 children[2]; UInt32 count = 0;
            if (audio.outputNumberOfChannels) children[count++] = BWStream;
            if (audio.inputNumberOfChannels) children[count++] = BWInputStream;
            return bytes(children, count * sizeof(*children));
        }
        return NSData.data;
    }
    if(object==BWSystem){
        if(selector=='bidp'){
            NSString *bundle=qualifier&&qualifierSize==sizeof(CFStringRef)?(__bridge NSString*)*(CFStringRef*)qualifier:nil;
            fprintf(stdout,"[native audio] HAL bundle lookup %s\n",bundle.UTF8String?:"(none)");
            return u32([bundle isEqualToString:@"com.apple.audio.CoreAudio"]?BWPlugin:0);
        }
        if(selector=='plg#')return u32(BWPlugin);
        if(selector=='dev#')return available?u32(BWDevice):NSData.data;
        if(selector=='dOut'||selector=='sOut')return u32(audio.outputNumberOfChannels?BWDevice:0);
        if(selector=='dIn ')return u32(audio.inputNumberOfChannels?BWDevice:0);
    }
    if(object==BWPlugin){
        if(selector==kAudioPlugInPropertyBundleID)return string(@"com.apple.audio.CoreAudio",retain);
        if(selector==kAudioPlugInPropertyDeviceList)return available?u32(BWDevice):NSData.data;
        if(selector==kAudioPlugInPropertyTranslateUIDToDevice){NSString *uid=qualifier&&qualifierSize==sizeof(CFStringRef)?(__bridge NSString*)*(CFStringRef*)qualifier:nil;return u32([uid isEqualToString:route.UID]?BWDevice:0);}
    }
    if(object==BWDevice){
        if(selector==kAudioDevicePropertyDeviceUID)return string(route.UID?:@"",retain);
        if(selector==kAudioDevicePropertyModelUID)return string(@"iPadOS.currentAudioRoute",retain);
        if(selector==kAudioDevicePropertyDeviceIsAlive)return u32(available);
        if(selector==kAudioDevicePropertyDeviceIsRunning||selector=='gone'){
            return u32(sharedAudio?atomic_load(&sharedAudio->actualRunning):0);
        }
        if(selector==kAudioDevicePropertyDeviceCanBeDefaultDevice||selector==kAudioDevicePropertyDeviceCanBeDefaultSystemDevice)return u32(channels > 0);
        if(selector==kAudioDevicePropertyIsHidden||selector==kAudioDevicePropertyClockDomain||selector==kAudioDevicePropertySafetyOffset||selector=='vfsz')return u32(0);
        if(selector==kAudioDevicePropertyTransportType){NSString *type=route.portType;return u32([type isEqual:AVAudioSessionPortUSBAudio]?'usb ':[type isEqual:AVAudioSessionPortBluetoothA2DP]?'blu2':[type isEqual:AVAudioSessionPortBluetoothHFP]?'blue':'bltn');}
        if(selector==kAudioDevicePropertyRelatedDevices)return u32(BWDevice);
        if(selector==kAudioDevicePropertyNominalSampleRate||selector=='asrt')return f64(audio.sampleRate);
        if(selector==kAudioDevicePropertyAvailableNominalSampleRates){AudioValueRange range={audio.sampleRate,audio.sampleRate};return bytes(&range,sizeof(range));}
        if(selector=='fsiz')return u32((UInt32)llround(audio.IOBufferDuration*audio.sampleRate));
        if(selector=='fsz#'){Float64 frames=llround(audio.IOBufferDuration*audio.sampleRate);AudioValueRange range={frames,frames};return bytes(&range,sizeof(range));}
        if(selector==kAudioDevicePropertyLatency)return u32((UInt32)llround((input?audio.inputLatency:audio.outputLatency)*audio.sampleRate));
        if(selector==kAudioDevicePropertyStreams)return channels?u32(input?BWInputStream:BWStream):NSData.data;
        if(selector=='slay'){AudioBufferList list={.mNumberBuffers=channels?1:0,.mBuffers={{.mNumberChannels=channels,.mDataByteSize=0,.mData=NULL}}};return bytes(&list,channels?sizeof(list):offsetof(AudioBufferList,mBuffers));}
        if(selector==kAudioDevicePropertyPreferredChannelsForStereo){UInt32 stereo[2]={1,channels>1?2:1};return bytes(stereo,sizeof(stereo));}
        if(selector==kAudioObjectPropertyControlList)return NSData.data;
        if(selector=='oink'){pid_t owner=-1;return bytes(&owner,sizeof(owner));}
    }
    if(object==BWStream || object==BWInputStream){
        if(selector==kAudioStreamPropertyDirection)return u32(input);
        if(selector==kAudioStreamPropertyIsActive)return u32(channels > 0);
        if(selector==kAudioStreamPropertyStartingChannel)return u32(1);
        if(selector==kAudioStreamPropertyTerminalType)return u32(input?kAudioStreamTerminalTypeMicrophone:kAudioStreamTerminalTypeSpeaker);
        if(selector==kAudioStreamPropertyLatency)return u32(0);
        AudioStreamBasicDescription format={.mSampleRate=audio.sampleRate,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagsNativeFloatPacked,.mBytesPerPacket=4*channels,.mFramesPerPacket=1,.mBytesPerFrame=4*channels,.mChannelsPerFrame=channels,.mBitsPerChannel=32};
        if(selector==kAudioStreamPropertyVirtualFormat||selector==kAudioStreamPropertyPhysicalFormat)return bytes(&format,sizeof(format));
        if(selector==kAudioStreamPropertyAvailableVirtualFormats||selector==kAudioStreamPropertyAvailablePhysicalFormats){AudioStreamRangedDescription range={.mFormat=format,.mSampleRateRange={audio.sampleRate,audio.sampleRate}};return bytes(&range,sizeof(range));}
    }
    return nil;
}
static void *coreSymbol(const char *name){static void *handle;static dispatch_once_t once;dispatch_once(&once,^{handle=dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio",RTLD_NOW);});return dlsym(handle,name);}
static void missing(const char *operation,AudioObjectID object,const AudioObjectPropertyAddress *address){UInt32 s=address->mSelector;fprintf(stderr,"[native audio] unsupported %s object=%08x selector=%c%c%c%c scope=%08x element=%u\n",operation,object,(s>>24)&255,(s>>16)&255,(s>>8)&255,s&255,address->mScope,address->mElement);}
Boolean AudioObjectHasProperty(AudioObjectID object,const AudioObjectPropertyAddress *address){if(ours(object))return property(object,address,0,NULL,NO)!=nil;return ((Boolean(*)(AudioObjectID,const AudioObjectPropertyAddress*))coreSymbol("AudioObjectHasProperty"))(object,address);}
OSStatus AudioObjectGetPropertyDataSize(AudioObjectID object,const AudioObjectPropertyAddress *address,UInt32 qualifierSize,const void *qualifier,UInt32 *size){
    directionalStreamQuery.scope = 0;
    if (ours(object)) {
        uint64_t generation = routeGeneration();
        NSData *value = property(object,address,qualifierSize,qualifier,NO);
        if (!value) { missing("size", object, address); return kAudioHardwareUnknownPropertyError; }
        *size = (UInt32)value.length;
        if (object == BWDevice && address->mSelector == kAudioDevicePropertyStreams &&
            (address->mScope == kAudioObjectPropertyScopeInput || address->mScope == kAudioObjectPropertyScopeOutput) &&
            generation && !(generation & 1) && generation == routeGeneration()) {
            directionalStreamQuery.scope = address->mScope;
            directionalStreamQuery.size = *size;
            directionalStreamQuery.generation = generation;
        }
        return noErr;
    }
    return ((OSStatus(*)(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32*))coreSymbol("AudioObjectGetPropertyDataSize"))(object,address,qualifierSize,qualifier,size);
}
OSStatus AudioObjectGetPropertyData(AudioObjectID object,const AudioObjectPropertyAddress *address,UInt32 qualifierSize,const void *qualifier,UInt32 *size,void *data){
    __typeof__(directionalStreamQuery) previous = directionalStreamQuery;
    directionalStreamQuery.scope = 0;
    if(object==BWSystem&&address->mSelector=='pibi'){
        typedef struct {void *input;UInt32 inputSize;void *output;UInt32 outputSize;} Translation;
        if(*size!=sizeof(Translation))return kAudioHardwareBadPropertySizeError;
        Translation *translation=data;if(translation->inputSize!=sizeof(CFStringRef)||translation->outputSize!=sizeof(UInt32))return kAudioHardwareBadPropertySizeError;
        NSString *bundle=(__bridge NSString*)*(CFStringRef*)translation->input;
        fprintf(stdout,"[native audio] legacy HAL lookup %s\n",bundle.UTF8String);
        *(UInt32*)translation->output=session()&&[bundle isEqualToString:@"com.apple.audio.CoreAudio"]?BWPlugin:0;return noErr;
    }
    if (ours(object)) {
        NSData *value = property(object,address,qualifierSize,qualifier,NO);
        AudioObjectPropertyAddress scoped = *address;
        if (object == BWDevice && address->mSelector == kAudioObjectPropertyOwnedObjects &&
            address->mScope == kAudioObjectPropertyScopeGlobal && address->mElement == kAudioObjectPropertyElementMain &&
            !qualifierSize && previous.scope && previous.size == *size && *size < value.length &&
            previous.generation == routeGeneration()) {
            // Bitwig sizes this particular read with the directional stream
            // selector, then fetches with the global owned-object address.
            scoped.mSelector = kAudioDevicePropertyStreams;
            scoped.mScope = previous.scope;
            address = &scoped;
            value = property(object,address,qualifierSize,qualifier,NO);
        }
        if (!value) { missing("get", object, address); return kAudioHardwareUnknownPropertyError; }
        if (*size < value.length) { missing("get size", object, address); return kAudioHardwareBadPropertySizeError; }
        value = property(object,address,qualifierSize,qualifier,YES);
        if (!value || *size < value.length) return kAudioHardwareBadPropertySizeError;
        if (value.length) memcpy(data, value.bytes, value.length);
        *size = (UInt32)value.length;
        return noErr;
    }
    return ((OSStatus(*)(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32*,void*))coreSymbol("AudioObjectGetPropertyData"))(object,address,qualifierSize,qualifier,size,data);
}
OSStatus AudioObjectIsPropertySettable(AudioObjectID object,const AudioObjectPropertyAddress *address,Boolean *settable){if(ours(object)){if(!property(object,address,0,NULL,NO))return kAudioHardwareUnknownPropertyError;*settable=object==BWDevice&&(address->mSelector==kAudioDevicePropertyNominalSampleRate||address->mSelector=='fsiz');return noErr;}return ((OSStatus(*)(AudioObjectID,const AudioObjectPropertyAddress*,Boolean*))coreSymbol("AudioObjectIsPropertySettable"))(object,address,settable);}
OSStatus AudioObjectSetPropertyData(AudioObjectID object,const AudioObjectPropertyAddress *address,UInt32 qualifierSize,const void *qualifier,UInt32 size,const void *data){
    if(ours(object)){NSError *error=nil;BOOL ok=NO;
        if(object==BWDevice&&address->mSelector==kAudioDevicePropertyNominalSampleRate&&size==sizeof(Float64))ok=[session() setPreferredSampleRate:*(Float64*)data error:&error];
        else if(object==BWDevice&&address->mSelector=='fsiz'&&size==sizeof(UInt32))ok=[session() setPreferredIOBufferDuration:*(UInt32*)data/session().sampleRate error:&error];
        else{missing("set",object,address);return kAudioHardwareUnknownPropertyError;}
        if(!ok)fprintf(stderr,"[native audio] preference failed: %s\n",error.description.UTF8String);return ok?noErr:kAudioHardwareIllegalOperationError;
    }
    return ((OSStatus(*)(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32,const void*))coreSymbol("AudioObjectSetPropertyData"))(object,address,qualifierSize,qualifier,size,data);
}
typedef OSStatus (*Listener)(AudioObjectID,UInt32,const AudioObjectPropertyAddress*,void*);
static NSMutableArray *listeners;
static NSLock *listenerLock;
static dispatch_source_t routeTimer;

static void prepareListeners(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        listeners = [NSMutableArray new];
        listenerLock = [NSLock new];
        __block uint64_t observed = routeGeneration();
        dispatch_queue_t queue = dispatch_queue_create("org.bitwigipad.audio-route", DISPATCH_QUEUE_SERIAL);
        routeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(routeTimer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                                  100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(routeTimer, ^{
            uint64_t generation = routeGeneration();
            if (!generation || (generation & 1) || generation == observed) return;
            session();
            observed = generation;
            [listenerLock lock];
            NSArray *copy = [listeners copy];
            [listenerLock unlock];
            for (NSDictionary *entry in copy) {
                AudioObjectPropertyAddress address;
                [entry[@"address"] getBytes:&address length:sizeof(address)];
                ((Listener)[entry[@"callback"] pointerValue])([entry[@"object"] unsignedIntValue], 1,
                                                            &address, [entry[@"context"] pointerValue]);
            }
        });
        dispatch_resume(routeTimer);
    });
}
OSStatus AudioObjectAddPropertyListener(AudioObjectID object,const AudioObjectPropertyAddress *address,Listener callback,void *context){
    if(ours(object)){prepareListeners();[listenerLock lock];[listeners addObject:@{@"object":@(object),@"address":bytes(address,sizeof(*address)),@"callback":[NSValue valueWithPointer:callback],@"context":[NSValue valueWithPointer:context]}];[listenerLock unlock];return noErr;}
    return ((OSStatus(*)(AudioObjectID,const AudioObjectPropertyAddress*,Listener,void*))coreSymbol("AudioObjectAddPropertyListener"))(object,address,callback,context);
}
OSStatus AudioObjectRemovePropertyListener(AudioObjectID object,const AudioObjectPropertyAddress *address,Listener callback,void *context){
    if(ours(object)){prepareListeners();NSData *key=bytes(address,sizeof(*address));[listenerLock lock];NSIndexSet *matches=[listeners indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry,NSUInteger i,BOOL *stop){return [entry[@"object"] unsignedIntValue]==object&&[entry[@"address"] isEqual:key]&&[entry[@"callback"] pointerValue]==callback&&[entry[@"context"] pointerValue]==context;}];[listeners removeObjectsAtIndexes:matches];[listenerLock unlock];return noErr;}
    return ((OSStatus(*)(AudioObjectID,const AudioObjectPropertyAddress*,Listener,void*))coreSymbol("AudioObjectRemovePropertyListener"))(object,address,callback,context);
}
