#import <Foundation/Foundation.h>

typedef struct { uint32_t eventClass, eventKind; } BWCarbonEventType;
typedef int32_t (*BWCarbonEventCallback)(void *, void *, void *);

@interface BWCarbonEvent : NSObject
@property(nonatomic) BWCarbonEventType type;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray *> *parameters;
@end
@implementation BWCarbonEvent
@end

@interface BWCarbonHandler : NSObject
@property(nonatomic) BWCarbonEventCallback callback;
@property(nonatomic) void *context;
@property(nonatomic, strong) NSData *types;
@end
@implementation BWCarbonHandler
@end

static NSMutableArray<BWCarbonHandler *> *handlers;
static uint8_t applicationTarget, applicationQueue;

void *GetApplicationEventTarget(void) { return &applicationTarget; }
void *GetCurrentEventQueue(void) { return &applicationQueue; }

int32_t CreateEvent(CFAllocatorRef allocator, uint32_t eventClass, uint32_t kind,
                    double time, uint32_t attributes, void **result) {
    if (!result) return -50;
    BWCarbonEvent *event = [BWCarbonEvent new];
    event.type = (BWCarbonEventType){eventClass, kind};
    event.parameters = [NSMutableDictionary new];
    *result = (__bridge_retained void *)event;
    return 0;
}
uint32_t GetEventClass(void *value) { return ((__bridge BWCarbonEvent *)value).type.eventClass; }
uint32_t GetEventKind(void *value) { return ((__bridge BWCarbonEvent *)value).type.eventKind; }

int32_t SetEventParameter(void *value, uint32_t name, uint32_t type, size_t length, const void *data) {
    if (!value || (length && !data)) return -50;
    BWCarbonEvent *event = (__bridge BWCarbonEvent *)value;
    event.parameters[@(name)] = @[@(type), [NSData dataWithBytes:data length:length]];
    return 0;
}
int32_t GetEventParameter(void *value, uint32_t name, uint32_t desiredType, uint32_t *actualType,
                          size_t capacity, size_t *actualSize, void *data) {
    BWCarbonEvent *event = (__bridge BWCarbonEvent *)value;
    NSArray *parameter = event.parameters[@(name)];
    if (!parameter) return -9870;
    uint32_t type = [parameter[0] unsignedIntValue];
    NSData *bytes = parameter[1];
    if (desiredType && desiredType != type && desiredType != '****') return -50;
    if (actualType) *actualType = type;
    if (actualSize) *actualSize = bytes.length;
    if (data && capacity < bytes.length) return -50;
    if (data && bytes.length) memcpy(data, bytes.bytes, bytes.length);
    return 0;
}
int32_t InstallEventHandler(void *target, BWCarbonEventCallback callback, size_t count,
                            const BWCarbonEventType *types, void *context, void **result) {
    if (!NSThread.isMainThread || target != &applicationTarget || !callback || !types || !count) return -50;
    BWCarbonHandler *handler = [BWCarbonHandler new];
    handler.callback = callback;
    handler.context = context;
    handler.types = [NSData dataWithBytes:types length:sizeof(*types) * count];
    @synchronized(BWCarbonHandler.class) {
        if (!handlers) handlers = [NSMutableArray new];
        [handlers addObject:handler];
        if (result) *result = (__bridge void *)handler;
    }
    return 0;
}
int32_t RemoveEventHandler(void *handle) {
    if (!NSThread.isMainThread || !handle) return -50;
    @synchronized(BWCarbonHandler.class) {
        NSUInteger index = [handlers indexOfObjectIdenticalTo:(__bridge id)handle];
        if (!handlers || index == NSNotFound) return -50;
        [handlers removeObjectAtIndex:index];
        return 0;
    }
}

int32_t PostEventToQueue(void *queue, void *value, int16_t priority) {
    if (queue != &applicationQueue || !value) return -50;
    BWCarbonEvent *event = (__bridge BWCarbonEvent *)value;
    NSArray<BWCarbonHandler *> *installed;
    @synchronized(BWCarbonHandler.class) { installed = [handlers copy]; }
    // The engine runs its AppKit loop inside a main-queue call.
    CFRunLoopRef mainLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{
        for (BWCarbonHandler *handler in installed.reverseObjectEnumerator) {
            const BWCarbonEventType *types = handler.types.bytes;
            NSUInteger count = handler.types.length / sizeof(*types);
            for (NSUInteger i = 0; i < count; i++) {
                if (types[i].eventClass != event.type.eventClass || types[i].eventKind != event.type.eventKind) continue;
                // Install and remove share this UI thread. A handler removed
                // after the event was posted is never called with stale context.
                if ([handlers containsObject:handler] &&
                    handler.callback(NULL, (__bridge void *)event, handler.context) != -9874) return;
                break;
            }
        }
    });
    CFRunLoopWakeUp(mainLoop);
    return 0;
}

// iPadOS has no Apple Help app or bundle-help registration service.
int32_t AHGotoPage(CFStringRef book, CFStringRef path, CFStringRef anchor) { return -4; }
int32_t AHRegisterHelpBook(const void *bundle) { return -4; }
