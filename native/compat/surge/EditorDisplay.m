#import <UIKit/UIKit.h>
#import <objc/message.h>

typedef void (*DisplayCallback)(uint32_t, uint32_t, void *);

@interface BWDisplayObserver : NSObject
@property(nonatomic) DisplayCallback callback;
@property(nonatomic) void *context;
@property(nonatomic, strong) NSArray *tokens;
@end
@implementation BWDisplayObserver
@end

static NSMutableArray<BWDisplayObserver *> *observers;

@implementation UIScreen (BWEditorDeviceDescription)
- (NSDictionary *)deviceDescription {
    return @{@"NSScreenNumber": @1, @"NSDeviceIsScreen": @YES,
             @"NSDeviceSize": [NSValue valueWithCGSize:self.bounds.size]};
}
@end

int32_t CGDisplayRegisterReconfigurationCallback(DisplayCallback callback, void *context) {
    if (!callback || !NSThread.isMainThread) return 1001;
    for (BWDisplayObserver *observer in observers)
        if (observer.callback == callback && observer.context == context) return 0;

    BWDisplayObserver *observer = [BWDisplayObserver new];
    observer.callback = callback;
    observer.context = context;
    NSMutableArray *tokens = [NSMutableArray new];
    __weak BWDisplayObserver *weakObserver = observer;
    for (NSString *name in @[UIScreenDidConnectNotification, UIScreenDidDisconnectNotification,
                              UIScreenModeDidChangeNotification, UIDeviceOrientationDidChangeNotification]) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
             queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            BWDisplayObserver *current = weakObserver;
            if (current) current.callback(1, 0, current.context);
        }];
        [tokens addObject:token];
    }
    observer.tokens = tokens;
    if (!observers) observers = [NSMutableArray new];
    [observers addObject:observer];
    return 0;
}

int32_t CGDisplayRemoveReconfigurationCallback(DisplayCallback callback, void *context) {
    if (!NSThread.isMainThread) return 1001;
    for (BWDisplayObserver *observer in observers.copy) {
        if (observer.callback != callback || observer.context != context) continue;
        for (id token in observer.tokens) [NSNotificationCenter.defaultCenter removeObserver:token];
        [observers removeObject:observer];
        return 0;
    }
    return 1001;
}

extern uint32_t CGMainDisplayID(void);

int32_t CGDisplayHideCursor(uint32_t display) {
    if (display != CGMainDisplayID()) return 1001;
    ((void (*)(id, SEL))objc_msgSend)(NSClassFromString(@"NSCursor"), @selector(hide));
    return 0;
}

int32_t CGDisplayShowCursor(uint32_t display) {
    if (display != CGMainDisplayID()) return 1001;
    ((void (*)(id, SEL))objc_msgSend)(NSClassFromString(@"NSCursor"), @selector(unhide));
    return 0;
}
