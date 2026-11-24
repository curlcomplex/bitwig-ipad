// Run in an iOS simulator with the built simulator libBitwigUIKit.dylib as argv[1].
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <assert.h>
#include <dlfcn.h>

@protocol FrameConstrained
- (void)setStyleMask:(NSUInteger)styleMask;
- (CGRect)constrainFrameRect:(CGRect)frame toScreen:(id)screen;
@end

@interface TestScreen : NSObject
@end
@implementation TestScreen
- (CGRect)visibleFrame { return CGRectMake(40, 30, 800, 600); }
@end

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
        [window setStyleMask:8];
        assert(CGRectEqualToRect([window constrainFrameRect:tall toScreen:screen], CGRectMake(65, 30, 320, 600)));
        puts("Inherited window frame constraints passed");
    }
}
