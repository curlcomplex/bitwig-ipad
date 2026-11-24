#import <UIKit/UIKit.h>
#import "Trace.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <GameController/GameController.h>
#include <mach/mach_time.h>

typedef struct { uint32_t unicodeEncoding, otherEncoding, mappingVersion; } BWUnicodeMapping;
uint32_t CreateTextEncoding(uint32_t base,uint32_t variant,uint32_t format) { return (base&0xffff)|((variant&0x7f)<<16)|((format&0x3f)<<26); }
int32_t CreateUnicodeToTextInfo(const BWUnicodeMapping *mapping,void **out) {
    if(!mapping||!out) return -50;
    uint32_t *encoding=malloc(sizeof(uint32_t)); if(!encoding) return -108;
    *encoding=mapping->otherEncoding; *out=encoding; return 0;
}
int32_t DisposeUnicodeToTextInfo(void **info) { if(!info) return -50; free(*info);*info=NULL;return 0; }
int32_t ConvertFromUnicodeToText(void *info,uint32_t inputBytes,const UniChar *input,uint32_t flags,uint32_t offsetCount,const uint32_t *offsets,uint32_t *outCount,uint32_t *outOffsets,uint32_t outputCapacity,uint32_t *inputRead,uint32_t *outputUsed,void *output) {
    if(!info||!input||!inputRead||!outputUsed||!output) return -50;
    CFStringEncoding encoding=*(uint32_t*)info;
    if(!CFStringIsEncodingAvailable(encoding)) return -8785;
    CFStringRef string=CFStringCreateWithCharacters(NULL,input,inputBytes/2);
    CFIndex bytes=0;
    CFIndex chars=CFStringGetBytes(string,CFRangeMake(0,inputBytes/2),encoding,0,false,output,outputCapacity,&bytes);
    *inputRead=(uint32_t)chars*2; *outputUsed=(uint32_t)bytes;
    uint32_t count=0;
    if(offsets&&outOffsets) for(uint32_t i=0;i<offsetCount&&offsets[i]<=*inputRead;i++) {
        CFIndex prefixBytes=0;
        CFStringGetBytes(string,CFRangeMake(0,offsets[i]/2),encoding,0,false,NULL,0,&prefixBytes);
        outOffsets[count++]=(uint32_t)prefixBytes;
    }
    if(outCount) *outCount=count;
    CFRelease(string);
    return chars==inputBytes/2 ? 0 : -8783;
}

// FSRef is an opaque 80-byte value. References issued here resolve to paths in
// the iOS app's standard directories; no desktop filesystem is fabricated.
static NSMutableArray<NSString*> *folderPaths;
int32_t FSFindFolder(int16_t domain,uint32_t type,unsigned char create,void *ref) {
    if(!ref) return -50;
    NSString *path=nil;
    NSSearchPathDirectory directory=0;
    switch(type) {
        case 'desk': case 'docs': directory=NSDocumentDirectory;break;
        case 'asup': directory=NSApplicationSupportDirectory;break;
        case 'cach': directory=NSCachesDirectory;break;
        case 'dlib': directory=NSLibraryDirectory;break;
        case 'pref': path=[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Preferences"];break;
        case 'temp': path=NSTemporaryDirectory();break;
        case 'cusr': path=NSHomeDirectory();break;
        default: BWCompatibilityTrace("bridge", "DesktopServices", "FSFindFolder", "unsupported_folder"); fprintf(stderr,"[compat] FSFindFolder unsupported type 0x%x domain %d\n",type,domain);return -43;
    }
    if(directory) path=NSSearchPathForDirectoriesInDomains(directory,NSUserDomainMask,YES).firstObject;
    if(!path) return -43;
    if(create&&![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil]) return -54;
    if(![NSFileManager.defaultManager fileExistsAtPath:path]) return -43;
    @synchronized(NSFileManager.class) {
        if(!folderPaths) folderPaths=[NSMutableArray new];
        [folderPaths addObject:path];
        uint64_t token[2]={0x4257465352454631,folderPaths.count-1};
        memset(ref,0,80);memcpy(ref,token,sizeof(token));
    }
    return 0;
}
int32_t FSRefMakePath(const void *ref,unsigned char *buffer,uint32_t capacity) {
    if(!ref||!buffer) return -50;
    uint64_t token[2];memcpy(token,ref,sizeof(token));
    @synchronized(NSFileManager.class) {
        if(token[0]!=0x4257465352454631||token[1]>=folderPaths.count) return -1401;
        const char *path=folderPaths[token[1]].fileSystemRepresentation;
        if(strlen(path)+1>capacity) return -2110;
        memcpy(buffer,path,strlen(path)+1);
    }
    return 0;
}

CFStringRef kTISPropertyUnicodeKeyLayoutData=CFSTR("kTISPropertyUnicodeKeyLayoutData");
static CFDictionaryRef keyboardSource(void) {
    static CFDictionaryRef source;
    static dispatch_once_t once;
    dispatch_once(&once,^{ uint32_t marker=0x42574b42; source=CFBridgingRetain(@{(__bridge NSString*)kTISPropertyUnicodeKeyLayoutData:[NSData dataWithBytes:&marker length:sizeof(marker)]}); });
    return source;
}
uint8_t LMGetKbdType(void) { return 40; }
CFTypeRef TISCopyCurrentKeyboardInputSource(void) { return CFRetain(keyboardSource()); }
CFTypeRef TISCopyCurrentKeyboardLayoutInputSource(void) { return CFRetain(keyboardSource()); }
CFTypeRef TISCopyInputSourceForLanguage(CFStringRef language) { return CFRetain(keyboardSource()); }
CFTypeRef TISGetInputSourceProperty(CFTypeRef source,CFStringRef property) { return source?CFDictionaryGetValue(source,property):NULL; }
int32_t UCKeyTranslate(const void *layout,uint16_t key,uint16_t action,uint32_t modifiers,uint32_t keyboardType,uint32_t options,uint32_t *dead,uint32_t capacity,uint32_t *length,UniChar *characters) {
    if(!layout||!length||!characters||!dead) return -50;
    // US shortcut labels for the initial keyboard profile. Actual text input is
    // delivered by UIKit, not reconstructed from physical key positions.
    static const char normal[]="asdfhgzxcv\0bqwerty123465=97-80]ou[ip\rlj'k;\\,/nm.\t `\177";
    static const char shifted[]="ASDFHGZXCV\0BQWERTY!@#$^%+(&_*})OU{IP\rLJ\"K:|<?NM>\t ~\177";
    *length=0;*dead=0;
    if(key>=sizeof(normal)-1||!normal[key]) return 0;
    if(!capacity) return -25340;
    characters[0]=(modifiers&2)?shifted[key]:normal[key];*length=1;return 0;
}

uint32_t CGMainDisplayID(void) { return 1; }
uint32_t CGDisplayPrimaryDisplay(uint32_t display) { return display==1?1:0; }
int32_t CGGetActiveDisplayList(uint32_t capacity,uint32_t *displays,uint32_t *count) { if(!count) return 1001;*count=1;if(capacity&&displays) displays[0]=1;return 0; }
CGSize CGDisplayScreenSize(uint32_t display) {
    // UIKit has no physical millimetre API. Expose a logical 96-points-per-inch
    // display size: Bitwig rejects a screen whose reported height is zero.
    // This is a scaling convention, not a measured panel dimension.
    CGSize points=UIScreen.mainScreen.bounds.size;
    return CGSizeMake(points.width*25.4/96.0,points.height*25.4/96.0);
}
bool CGCursorIsVisible(void) { return GCMouse.current!=nil; }
int32_t CGDisplayMoveCursorToPoint(uint32_t display,CGPoint point) { return 1004; } // iPadOS has no cursor-warp API.
int32_t CGAssociateMouseAndMouseCursorPosition(bool associated) { return associated?0:1004; }

typedef int32_t (^BWDisplayHandler)(void*,const CVTimeStamp*,const CVTimeStamp*,uint64_t,uint64_t*);
@interface BWUIKitDisplayLink : NSObject
@property(nonatomic,strong) CADisplayLink *link;
@property(nonatomic,copy) BWDisplayHandler handler;
@end
@implementation BWUIKitDisplayLink
- (void)tick:(CADisplayLink*)link {
    if(!self.handler) return;
    CVTimeStamp now={0},next={0};
    now.videoTimeScale=1000000000;now.videoTime=(int64_t)(link.timestamp*1e9);now.hostTime=mach_absolute_time();
    now.rateScalar=1;now.videoRefreshPeriod=(int64_t)(link.duration*1e9);
    now.flags=kCVTimeStampVideoTimeValid|kCVTimeStampHostTimeValid|kCVTimeStampVideoRefreshPeriodValid|kCVTimeStampRateScalarValid;
    next=now;next.videoTime=(int64_t)(link.targetTimestamp*1e9);
    uint64_t flags=0;self.handler((__bridge void*)self,&now,&next,0,&flags);
}
@end
int32_t CVDisplayLinkCreateWithCGDisplay(uint32_t display,void **output) { if(!output||display!=1)return -6661;*output=(__bridge_retained void*)[BWUIKitDisplayLink new];return 0; }
int32_t CVDisplayLinkCreateWithActiveCGDisplays(void **output) { return CVDisplayLinkCreateWithCGDisplay(1,output); }
int32_t CVDisplayLinkSetOutputHandler(void *value,BWDisplayHandler handler) { if(!value)return -6661;((__bridge BWUIKitDisplayLink*)value).handler=handler;return 0; }
int32_t CVDisplayLinkStart(void *value) {
    if(!value)return -6661;BWUIKitDisplayLink *object=(__bridge id)value;
    dispatch_async(dispatch_get_main_queue(),^{ if(!object.link){object.link=[CADisplayLink displayLinkWithTarget:object selector:@selector(tick:)];[object.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];}object.link.paused=NO; });return 0;
}
int32_t CVDisplayLinkStop(void *value) { if(!value)return -6661;BWUIKitDisplayLink *object=(__bridge id)value;dispatch_async(dispatch_get_main_queue(),^{object.link.paused=YES;});return 0; }
void CVDisplayLinkRelease(void *value) { if(!value)return;BWUIKitDisplayLink *object=CFBridgingRelease(value);dispatch_async(dispatch_get_main_queue(),^{[object.link invalidate];object.link=nil;}); }
