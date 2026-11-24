// Run in an ARM64 iOS Simulator, passing libBitwigUIKit.dylib and optionally --native-compat-trace.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../native/compat/Trace.h"
#include <assert.h>
#include <dlfcn.h>

@protocol TestedPasteboard
+ (id<TestedPasteboard>)pasteboardWithName:(NSString *)name;
- (NSInteger)declareTypes:(NSArray *)types owner:(id)owner;
- (NSInteger)clearContents;
- (NSInteger)changeCount;
- (NSArray *)types;
- (NSArray *)pasteboardItems;
- (BOOL)writeObjects:(NSArray *)items;
- (NSData *)dataForType:(NSString *)type;
- (NSString *)stringForType:(NSString *)type;
- (BOOL)setData:(NSData *)value forType:(NSString *)type;
- (BOOL)setString:(NSString *)value forType:(NSString *)type;
@end

@interface TestPasteboardOwner : NSObject
@property NSUInteger requests;
@property NSUInteger losses;
@property BOOL redeclareOnRead;
@end
@implementation TestPasteboardOwner
- (void)pasteboard:(id<TestedPasteboard>)board provideDataForType:(NSString *)type {
    self.requests++;
    if(self.redeclareOnRead) [board declareTypes:@[type] owner:nil];
    assert([board setString:@"promised value" forType:type]);
}
- (void)pasteboardChangedOwner:(id)board { self.losses++; }
@end

static void testDeclaredPasteboard(void) {
    Class<TestedPasteboard> boardClass = (Class<TestedPasteboard>)NSClassFromString(@"NSPasteboard");
    id<TestedPasteboard> board = [boardClass pasteboardWithName:@"boundary-test"];
    NSString *a = @"com.test.bitwig.pasteboard.first";
    NSString *b = @"com.test.bitwig.pasteboard.second";
    NSString *c = @"com.test.bitwig.pasteboard.appended";
    TestPasteboardOwner *owner = [TestPasteboardOwner new];
    NSInteger before = board.changeCount;
    assert([board declareTypes:@[] owner:nil] == before + 1);
    assert(board.pasteboardItems.count == 0);
    NSInteger declared = [board declareTypes:@[a,b] owner:owner];
    assert((declared == before + 2 && [board.types isEqual:@[a,b]]));
    assert(board.pasteboardItems.count == 1 && owner.requests == 0);
    id<TestedPasteboard> first = board.pasteboardItems.firstObject;
    assert([[board stringForType:a] isEqual:@"promised value"] && owner.requests == 1);
    assert([[board stringForType:a] isEqual:@"promised value"] && owner.requests == 1);
    NSData *bytes = [NSData dataWithBytes:"\0\xff" length:2];
    assert([board setData:bytes forType:b]);
    assert([[first dataForType:b] isEqual:bytes]);
    id<TestedPasteboard> appended = [NSClassFromString(@"NSPasteboardItem") new];
    assert([appended setString:@"appended" forType:c]);
    assert([board writeObjects:@[appended]]);
    assert(board.pasteboardItems.count == 2 && [board.types containsObject:c]);
    assert([first dataForType:c] == nil && [[board stringForType:c] isEqual:@"appended"]);
    assert(board.changeCount == declared && owner.losses == 0);
    [board declareTypes:@[b] owner:owner];
    [board declareTypes:@[a] owner:nil];
    assert(first.types.count == 0 && [first dataForType:b] == nil);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    assert(owner.losses == 1);
    assert([board clearContents] == declared + 3 && board.pasteboardItems.count == 0);
    owner.redeclareOnRead = YES;
    [board declareTypes:@[a] owner:owner];
    assert([board stringForType:a] == nil);
    assert([[board stringForType:a] isEqual:@"promised value"]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        assert(argc >= 2);
        void *bridge = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        assert(bridge);
        Class base = NSClassFromString(@"NSView");
        assert(base);
        Class subclass = objc_allocateClassPair(base, "BoundaryView", 0);
        assert(subclass);
        objc_registerClassPair(subclass);
        UIView *view = [[subclass alloc] initWithFrame:CGRectMake(20, 30, 200, 100)];
        UIView *child = [[UIView alloc] initWithFrame:CGRectMake(6, 7, 50, 30)];
        [view addSubview:child];
        CGRect frame = view.frame;
        CGRect childFrame = child.frame;
        ((void (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(@"viewWillStartLiveResize"));
        ((void (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(@"viewDidEndLiveResize"));
        assert(CGRectEqualToRect(view.frame, frame) && CGRectEqualToRect(child.frame, childFrame));

        SEL missing = NSSelectorFromString(@"bw_testUnknownSelector");
        for (id target in @[view, subclass]) {
            BOOL rejected = NO;
            @try {
                ((void (*)(id, SEL))objc_msgSend)(target, missing);
            } @catch (NSException *exception) {
                rejected = [exception.name isEqual:NSInvalidArgumentException] &&
                           [exception.reason containsString:@"bw_testUnknownSelector"];
                printf("%s %s\n", exception.name.UTF8String, rejected ? "preserved" : "changed");
            }
            assert(rejected);
        }

        (void)BWCompatibilityTracing();
        dlerror();
        assert(dlsym(bridge, "bw_testUnknownSymbol") == NULL);
        errno = ERANGE;
        BWCompatibilityTrace("dlsym", "test", "bw_testUnknownSymbol", "missing");
        assert(errno == ERANGE);
        assert(dlerror() != NULL);
        testDeclaredPasteboard();
        puts("Inherited defaults, Objective-C rejection, loader diagnostics, and named pasteboard passed");
    }
}
