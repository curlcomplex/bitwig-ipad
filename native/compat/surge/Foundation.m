#import <Foundation/Foundation.h>

@interface NSAppleEventManager : NSObject
@end

@implementation NSAppleEventManager {
    NSMapTable<NSNumber *, id> *_handlers;
    NSMutableDictionary<NSNumber *, NSString *> *_selectors;
}
+ (instancetype)sharedAppleEventManager {
    static NSAppleEventManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [self new]; });
    return manager;
}
- (instancetype)init {
    if ((self = [super init])) {
        _handlers = [NSMapTable strongToWeakObjectsMapTable];
        _selectors = [NSMutableDictionary new];
    }
    return self;
}
// iPadOS supplies no Apple Event transport. Retain just the local registration.
- (void)setEventHandler:(id)target andSelector:(SEL)selector forEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID {
    NSNumber *key = @(((uint64_t)eventClass << 32) | eventID);
    @synchronized (self) {
        [_handlers setObject:target forKey:key];
        _selectors[key] = NSStringFromSelector(selector);
    }
}
- (void)removeEventHandlerForEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID {
    NSNumber *key = @(((uint64_t)eventClass << 32) | eventID);
    @synchronized (self) {
        [_handlers removeObjectForKey:key];
        [_selectors removeObjectForKey:key];
    }
}
@end

@interface NSAppleScript : NSObject
- (instancetype)initWithSource:(NSString *)source;
- (id)executeAndReturnError:(NSDictionary **)error;
@end

@implementation NSAppleScript
- (instancetype)initWithSource:(NSString *)source {
    return [super init];
}
- (id)executeAndReturnError:(NSDictionary **)error {
    if (error) *error = @{@"NSAppleScriptErrorMessage": @"AppleScript is unavailable on iPadOS",
                          @"NSAppleScriptErrorNumber": @(-4)};
    return nil;
}
@end
