// Run in an iOS simulator with the simulator libBitwigUIKit.dylib on the library path.
#import <UIKit/UIKit.h>
#include <assert.h>

@interface NSView : UIView @end
@interface NSGestureRecognizer : NSObject
@property(nonatomic) NSUInteger allowedTouchTypes;
@property(nonatomic, weak) id delegate;
@property(nonatomic, weak) NSView *view;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)reset;
@end
@interface NSEvent : NSObject
- (NSSet *)touchesMatchingPhase:(NSUInteger)phases inView:(UIView *)view;
@end
@interface NSTouch : NSObject
@property(nonatomic, readonly) NSNumber *identity;
@property(nonatomic, readonly) NSInteger type;
- (CGPoint)locationInView:(UIView *)view;
@end

@interface TestRecognizer : NSGestureRecognizer
@property(nonatomic, strong) NSMutableArray<NSArray *> *deliveries;
@property(nonatomic) NSUInteger resets;
@end
@implementation TestRecognizer
- (instancetype)init {
    if ((self = [super initWithTarget:nil action:NULL])) {
        self.allowedTouchTypes = 1;
        self.delegate = self;
        self.deliveries = [NSMutableArray new];
    }
    return self;
}
- (BOOL)gestureRecognizer:(NSGestureRecognizer *)recognizer shouldReceiveTouch:(NSTouch *)touch {
    return touch.type == 0;
}
- (void)capture:(NSEvent *)event phase:(NSUInteger)phase {
    NSSet *touches = [event touchesMatchingPhase:phase inView:nil];
    NSSet *stationary = [event touchesMatchingPhase:4 inView:nil];
    NSMutableDictionary *contacts = [NSMutableDictionary new];
    for (NSTouch *touch in touches) {
        CGPoint inWindow = [touch locationInView:nil];
        CGPoint inView = [touch locationInView:self.view];
        assert(CGPointEqualToPoint(inView, CGPointMake(inWindow.x - 10, 180 - inWindow.y)));
        contacts[touch.identity] = [NSValue valueWithCGPoint:inWindow];
    }
    [self.deliveries addObject:@[@(phase), contacts, stationary]];
}
- (void)touchesBeganWithEvent:(NSEvent *)event { [self capture:event phase:1]; }
- (void)touchesMovedWithEvent:(NSEvent *)event { [self capture:event phase:2]; }
- (void)touchesEndedWithEvent:(NSEvent *)event { [self capture:event phase:8]; }
- (void)touchesCancelledWithEvent:(NSEvent *)event { [self capture:event phase:16]; }
- (void)reset { [super reset]; self.resets++; }
@end

@interface TestView : NSView
@property(nonatomic, strong) UIWindow *testWindow;
@property(nonatomic) NSUInteger mouseMoves, mouseDowns, mouseUps, mouseDrags;
@end
@implementation TestView
- (UIWindow *)window { return self.testWindow; }
- (BOOL)becomeFirstResponder { return YES; }
- (void)mouseMoved:(NSEvent *)event { self.mouseMoves++; }
- (void)mouseDown:(NSEvent *)event { self.mouseDowns++; }
- (void)mouseUp:(NSEvent *)event { self.mouseUps++; }
- (void)mouseDragged:(NSEvent *)event { self.mouseDrags++; }
@end

@interface TestTouch : NSObject
@property(nonatomic) UITouchType type;
@property(nonatomic) CGPoint point;
@end
@implementation TestTouch
- (CGPoint)locationInView:(UIView *)view { return self.point; }
- (CGPoint)previousLocationInView:(UIView *)view { return self.point; }
- (NSTimeInterval)timestamp { return 1; }
- (NSUInteger)tapCount { return 1; }
- (CGFloat)force { return 1; }
@end

int main(void) {
    @autoreleasepool {
        UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 320, 200)];
        TestView *view = [[TestView alloc] initWithFrame:CGRectMake(10, 20, 300, 160)];
        view.testWindow = window;
        [window addSubview:view];
        TestRecognizer *recognizer = [TestRecognizer new];
        [view addGestureRecognizer:(id)recognizer];
        assert(view.multipleTouchEnabled && recognizer.view == view);
        UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:nil action:NULL];
        [view addGestureRecognizer:hover];
        assert([view.gestureRecognizers containsObject:hover]);
        TestTouch *left = [TestTouch new], *right = [TestTouch new];
        left.point = CGPointMake(30, 70);
        right.point = CGPointMake(50, 90);
        [view touchesBegan:(id)[NSSet setWithObjects:left,right,nil] withEvent:nil];
        NSDictionary *began = recognizer.deliveries[0][1];
        assert(began.count == 2);
        NSNumber *leftID = [began allKeysForObject:[NSValue valueWithCGPoint:CGPointMake(30,130)]].firstObject;
        NSNumber *rightID = [began allKeysForObject:[NSValue valueWithCGPoint:CGPointMake(50,110)]].firstObject;
        assert(leftID && rightID && ![leftID isEqual:rightID]);
        left.point = CGPointMake(80,100);
        [view touchesMoved:(id)[NSSet setWithObject:left] withEvent:nil];
        assert([recognizer.deliveries[1][1][leftID] isEqual:[NSValue valueWithCGPoint:CGPointMake(80,100)]]);
        assert([recognizer.deliveries[1][2] count] == 1);
        [view touchesEnded:(id)[NSSet setWithObject:left] withEvent:nil];
        assert(recognizer.deliveries[2][1][leftID] && recognizer.resets == 0);
        [view touchesCancelled:(id)[NSSet setWithObject:right] withEvent:nil];
        assert(recognizer.deliveries[3][1][rightID] && recognizer.resets == 1);
        assert(view.mouseMoves + view.mouseDowns + view.mouseUps + view.mouseDrags == 0);
        [view touchesBegan:(id)[NSSet setWithObject:left] withEvent:nil];
        [view removeGestureRecognizer:(id)recognizer];
        [view touchesEnded:(id)[NSSet setWithObject:left] withEvent:nil];
        assert(recognizer.deliveries.count == 5 && recognizer.resets == 2);
        assert(view.mouseUps == 0 && [view.gestureRecognizers containsObject:hover]);
        [view addGestureRecognizer:(id)recognizer];
        left.type = UITouchTypeIndirectPointer;
        [view touchesBegan:(id)[NSSet setWithObject:left] withEvent:nil];
        [view touchesMoved:(id)[NSSet setWithObject:left] withEvent:nil];
        [view touchesEnded:(id)[NSSet setWithObject:left] withEvent:nil];
        assert(recognizer.deliveries.count == 5);
        assert(view.mouseMoves == 1 && view.mouseDowns == 1 && view.mouseDrags == 1 && view.mouseUps == 1);
        left.type = UITouchTypeDirect;
        [view touchesBegan:(id)[NSSet setWithObject:left] withEvent:nil];
        [view willMoveToWindow:nil];
        assert([recognizer.deliveries[6][0] unsignedIntegerValue] == 16);
        assert(recognizer.resets == 3);
        [view touchesEnded:(id)[NSSet setWithObject:left] withEvent:nil];
        assert(recognizer.deliveries.count == 7 && view.mouseUps == 1);
        puts("Direct touch identity, coordinates, staggered release, lifecycle cancellation and mouse/hover routing passed");
    }
}
