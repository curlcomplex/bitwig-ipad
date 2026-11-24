// Run in an iOS simulator with the built simulator libBitwigUIKit.dylib as argv[1].
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <assert.h>
#include <dlfcn.h>

@protocol FrameConstrained
- (void)setStyleMask:(NSUInteger)styleMask;
- (void)setCollectionBehavior:(NSUInteger)behavior;
- (void)setMovable:(BOOL)movable;
- (BOOL)isMovable;
- (BOOL)bwFollowsScene;
- (void)setFrame:(CGRect)frame display:(BOOL)display;
- (CGRect)frame;
- (void)orderFront:(id)sender;
- (CGRect)constrainFrameRect:(CGRect)frame toScreen:(id)screen;
@end

@interface TestScreen : NSObject
@end
@implementation TestScreen
- (CGRect)visibleFrame { return CGRectMake(40, 30, 800, 600); }
@end

static CGRect testSceneBounds(id self, SEL command) { return CGRectMake(0, 0, 1133, 744); }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        assert(argc == 2);
        if (!dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) {
            fprintf(stderr, "%s\n", dlerror());
            return 1;
        }
        Class base = NSClassFromString(@"NSWindow");
        assert(base);
        Class subclass = objc_allocateClassPair(base, "FrameConstraintTestWindow", 0);
        assert(subclass);
        assert(class_addMethod(subclass, sel_registerName("bwSceneBounds"), (IMP)testSceneBounds, "{CGRect={CGPoint=dd}{CGSize=dd}}@:"));
        objc_registerClassPair(subclass);
        id<FrameConstrained> window = [[subclass alloc] init];
        TestScreen *screen = [TestScreen new];
        CGRect unchanged = CGRectMake(80, 40, 320, 160);
        CGRect above = CGRectMake(65, 610, 320, 160);
        CGRect below = CGRectMake(-10, -200, 320, 160);
        CGRect tall = CGRectMake(65, 40, 320, 1000);
        assert(CGRectEqualToRect([window constrainFrameRect:unchanged toScreen:screen], unchanged));
        assert(CGRectEqualToRect([window constrainFrameRect:above toScreen:screen], CGRectMake(65, 470, 320, 160)));
        assert(CGRectEqualToRect([window constrainFrameRect:below toScreen:screen], CGRectMake(-10, 30, 320, 160)));
        assert(CGRectEqualToRect([window constrainFrameRect:tall toScreen:screen], CGRectMake(65, -370, 320, 1000)));
        [window setStyleMask:32783];
        [window setMovable:YES];
        [window setCollectionBehavior:1u << 8];
        assert(![window bwFollowsScene] && [window isMovable]);
        assert(CGRectEqualToRect([window constrainFrameRect:tall toScreen:screen], CGRectMake(65, 30, 320, 600)));
        [window setFrame:unchanged display:NO];
        [window setCollectionBehavior:1u << 7];
        assert(![window bwFollowsScene] && [window isMovable]);
        assert(CGRectEqualToRect([window frame], unchanged));
        [window orderFront:nil];
        [window setFrame:CGRectMake(0, 0, 1133, 744) display:NO];
        assert(![window bwFollowsScene] && [window isMovable]);

        id<FrameConstrained> editor = [[subclass alloc] init];
        [editor setStyleMask:32783];
        [editor setMovable:YES];
        [editor setFrame:CGRectMake(0, 0, 1133, 744) display:NO];
        [editor setCollectionBehavior:1u << 7];
        assert([editor bwFollowsScene] && ![editor isMovable]);
        [editor setFrame:above display:NO];
        assert(![editor bwFollowsScene] && [editor isMovable]);
        [editor setFrame:CGRectMake(0, 0, 1133, 744) display:NO];
        [editor orderFront:nil];
        [editor setFrame:above display:NO];
        assert(CGRectEqualToRect([editor frame], CGRectMake(0, 0, 1133, 744)));
        [editor setCollectionBehavior:1u << 8];
        assert(![editor bwFollowsScene] && [editor isMovable]);
        assert(CGRectEqualToRect([editor frame], above));
        puts("Inherited window frame constraints passed");
    }
}
