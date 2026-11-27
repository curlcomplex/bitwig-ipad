// Run in an iOS simulator with the simulator libBitwigUIKit.dylib on the library path.
#import <UIKit/UIKit.h>
#include <assert.h>

@interface NSView : UIView
- (BOOL)handleHardwarePress:(UIPress *)press down:(BOOL)down;
- (void)cancelHardwareKeys;
@end
@interface NSGestureRecognizer : NSObject
@property(nonatomic) NSUInteger allowedTouchTypes;
@property(nonatomic, weak) id delegate;
@property(nonatomic, weak) NSView *view;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)reset;
@end
@interface NSEvent : NSObject
@property(nonatomic, readonly) NSUInteger modifierFlags;
@property(nonatomic, readonly) NSInteger type, buttonNumber;
@property(nonatomic, readonly) unsigned short keyCode;
@property(nonatomic, readonly) BOOL isARepeat;
@property(nonatomic, readonly) NSString *charactersIgnoringModifiers;
+ (NSUInteger)pressedMouseButtons;
+ (CGPoint)mouseLocation;
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
@property(nonatomic, strong) NSMutableArray<NSEvent *> *secondaryEvents, *keyEvents;
@end
@implementation TestView
- (UIWindow *)window { return self.testWindow; }
- (BOOL)becomeFirstResponder { return YES; }
- (void)mouseMoved:(NSEvent *)event { self.mouseMoves++; }
- (void)mouseDown:(NSEvent *)event { self.mouseDowns++; }
- (void)mouseUp:(NSEvent *)event { self.mouseUps++; }
- (void)mouseDragged:(NSEvent *)event { self.mouseDrags++; }
- (void)rightMouseDown:(NSEvent *)event { assert(NSEvent.pressedMouseButtons == 2); [self.secondaryEvents addObject:event]; }
- (void)rightMouseDragged:(NSEvent *)event { assert(NSEvent.pressedMouseButtons == 2); [self.secondaryEvents addObject:event]; }
- (void)rightMouseUp:(NSEvent *)event { assert(NSEvent.pressedMouseButtons == 0); [self.secondaryEvents addObject:event]; }
- (void)keyDown:(NSEvent *)event { [self.keyEvents addObject:event]; }
- (void)keyUp:(NSEvent *)event { [self.keyEvents addObject:event]; }
- (void)flagsChanged:(NSEvent *)event { [self.keyEvents addObject:event]; }
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

@interface TestInputEvent : NSObject
@property(nonatomic) UIEventButtonMask buttonMask;
@property(nonatomic) UIKeyModifierFlags modifierFlags;
@end
@implementation TestInputEvent @end

@interface TestKey : NSObject
@property(nonatomic) UIKeyboardHIDUsage keyCode;
@property(nonatomic) UIKeyModifierFlags modifierFlags;
@property(nonatomic, copy) NSString *characters, *charactersIgnoringModifiers;
@end
@implementation TestKey @end

@interface TestPress : NSObject
@property(nonatomic, strong) TestKey *key;
@end
@implementation TestPress
- (NSTimeInterval)timestamp { return 1; }
@end

static void testHardware(TestView *view) {
    view.secondaryEvents = [NSMutableArray new];
    view.keyEvents = [NSMutableArray new];
    NSUInteger previousLeftDowns = view.mouseDowns;
    TestTouch *pointer = [TestTouch new];
    pointer.type = UITouchTypeIndirectPointer;
    pointer.point = CGPointMake(50, 60);
    NSSet *touches = [NSSet setWithObject:pointer];
    TestInputEvent *input = [TestInputEvent new];
    input.buttonMask = UIEventButtonMaskSecondary;
    input.modifierFlags = UIKeyModifierShift;
    [view touchesBegan:(id)touches withEvent:(id)input];
    input.buttonMask = 0;
    [view touchesMoved:(id)touches withEvent:(id)input];
    [view touchesCancelled:(id)touches withEvent:(id)input];
    assert(view.mouseDowns == previousLeftDowns);
    assert(view.secondaryEvents.count == 3);
    assert(view.secondaryEvents[0].type == 3 && view.secondaryEvents[1].type == 7 && view.secondaryEvents[2].type == 4);
    for (NSEvent *event in view.secondaryEvents) assert(event.buttonNumber == 1 && event.modifierFlags == UIKeyModifierShift);

    TestPress *chord = [TestPress new];
    chord.key = [TestKey new];
    chord.key.keyCode = UIKeyboardHIDUsageKeyboardLeftGUI;
    assert([view handleHardwarePress:(id)chord down:YES]);
    assert(view.keyEvents.lastObject.type == 12 && view.keyEvents.lastObject.keyCode == 55);
    assert(view.keyEvents.lastObject.modifierFlags == UIKeyModifierCommand);
    TestPress *key = [TestPress new];
    key.key = [TestKey new];
    key.key.keyCode = UIKeyboardHIDUsageKeyboardD;
    key.key.characters = key.key.charactersIgnoringModifiers = @"d";
    key.key.modifierFlags = UIKeyModifierCommand;
    assert([view handleHardwarePress:(id)key down:YES]);
    assert(view.keyEvents.lastObject.type == 10 && view.keyEvents.lastObject.keyCode == 2);
    assert([view.keyEvents.lastObject.charactersIgnoringModifiers isEqualToString:@"d"]);
    assert(!view.keyEvents.lastObject.isARepeat);
    assert([view handleHardwarePress:(id)key down:YES]);
    assert(view.keyEvents.lastObject.isARepeat);
    assert([view handleHardwarePress:(id)key down:NO]);
    assert(view.keyEvents.lastObject.type == 11 && !view.keyEvents.lastObject.isARepeat);
    assert([view handleHardwarePress:(id)chord down:NO]);
    assert(view.keyEvents.lastObject.type == 12 && view.keyEvents.lastObject.modifierFlags == 0);

    chord.key.keyCode = UIKeyboardHIDUsageKeyboardLeftControl;
    assert([view handleHardwarePress:(id)chord down:YES]);
    assert(view.keyEvents.lastObject.modifierFlags == UIKeyModifierControl);
    [view cancelHardwareKeys];
    assert(view.keyEvents.lastObject.modifierFlags == 0);
    assert(![view handleHardwarePress:(id)chord down:NO]);
    chord.key.keyCode = UIKeyboardHIDUsageKeyboardCapsLock;
    NSUInteger beforeCaps = view.keyEvents.count;
    assert([view handleHardwarePress:(id)chord down:YES]);
    assert([view handleHardwarePress:(id)chord down:YES]);
    assert([view handleHardwarePress:(id)chord down:NO]);
    assert(view.keyEvents.count == beforeCaps + 1);
    assert(view.keyEvents.lastObject.type == 12 && view.keyEvents.lastObject.keyCode == 57);
    assert([view handleHardwarePress:(id)chord down:YES]);
    [view cancelHardwareKeys];
    assert([view handleHardwarePress:(id)chord down:NO]);
    assert(view.keyEvents.count == beforeCaps + 2);
}

@interface UIWindow (DesktopDragTest)
- (CGPoint)convertPointToScreen:(CGPoint)point;
- (void)setFrameOrigin:(CGPoint)origin;
- (CGPoint)convertEventScreenLocationBackingStore:(CGPoint)location;
- (CGPoint)mouseLocationOutsideOfEventStream;
@end

@interface NSWindow : NSObject
- (void)setFrame:(CGRect)frame display:(BOOL)display;
@end

@interface NSScreen : NSObject @end
@interface NSScreen (ScreenEdgeTest)
+ (instancetype)primaryScreen;
+ (instancetype)screenForFrameRect:(CGRect)rect;
+ (CGPoint)flippedCoordinate:(CGPoint)point inRect:(CGRect)rect;
- (CGRect)pixelBounds;
@end
@implementation NSScreen (ScreenEdgeTest)
+ (instancetype)primaryScreen { return [self new]; }
+ (instancetype)screenForFrameRect:(CGRect)rect {
    CGRect hit = CGRectIntersection(rect, CGRectMake(0, 0, 1133, 744));
    return CGRectIsEmpty(hit) ? nil : [self primaryScreen];
}
+ (CGPoint)flippedCoordinate:(CGPoint)point inRect:(CGRect)rect {
    return CGPointMake(point.x, CGRectGetMaxY(rect) - point.y);
}
- (CGRect)pixelBounds { return CGRectMake(0, 0, 2266, 1488); }
@end

@interface DragTestDesktopWindow : NSObject
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic) CGRect frame;
@end

@implementation DragTestDesktopWindow
- (CGRect)convertRectToGlobalPixels:(CGRect)rect {
    return CGRectApplyAffineTransform(rect, CGAffineTransformMakeScale(2, 2));
}
- (CGPoint)convertEventScreenLocationBackingStore:(CGPoint)location {
    CGRect rect = CGRectMake(location.x, location.y, 1, 1);
    if ([NSScreen screenForFrameRect:rect]) rect = [self convertRectToGlobalPixels:rect];
    return [NSScreen flippedCoordinate:rect.origin inRect:NSScreen.primaryScreen.pixelBounds];
}
- (CGPoint)convertPointToScreen:(CGPoint)point {
    return CGPointMake(self.frame.origin.x + point.x, self.frame.origin.y + point.y);
}
- (void)setFrameOrigin:(CGPoint)origin {
    CGRect frame = self.frame;
    frame.origin = origin;
    self.frame = frame;
    frame.origin.y = 744 - CGRectGetMaxY(frame);
    self.window.frame = frame;
}
@end

@interface BWDirectTouchRecognizer : NSGestureRecognizer
@property(nonatomic) CGPoint startOrigin, startScreen;
@property(nonatomic) BOOL dragging;
@end

@implementation BWDirectTouchRecognizer
- (instancetype)init {
    if ((self = [super initWithTarget:nil action:NULL])) self.allowedTouchTypes = 1;
    return self;
}
- (CGPoint)screenPointOfTouch:(NSTouch *)touch {
    return [self.view.window convertPointToScreen:[touch locationInView:nil]];
}
- (void)setWindowDragTouch:(NSTouch *)touch {
    self.startScreen = [self screenPointOfTouch:touch];
    self.startOrigin = self.view.window.frame.origin;
    self.dragging = YES;
}
- (void)touchesBeganWithEvent:(NSEvent *)event {
    [self setWindowDragTouch:[event touchesMatchingPhase:1 inView:nil].anyObject];
}
- (BOOL)dragWindowWithTouch:(NSTouch *)touch {
    if (!self.dragging) return NO;
    CGPoint point = [self screenPointOfTouch:touch];
    [self.view.window setFrameOrigin:CGPointMake(self.startOrigin.x + point.x - self.startScreen.x,
                                                self.startOrigin.y + point.y - self.startScreen.y)];
    return YES;
}
- (void)touchesMovedWithEvent:(NSEvent *)event {
    [self dragWindowWithTouch:[event touchesMatchingPhase:2 inView:nil].anyObject];
}
- (void)reset { [super reset]; self.dragging = NO; }
@end

@interface BWView : TestView @end
@implementation BWView @end

static void testDesktopDrag(void) {
    UIWindow *window = [[NSClassFromString(@"BWUIKitWindow") alloc] initWithFrame:CGRectZero];
    NSWindow *appKitWindow = [NSWindow new];
    [window setValue:appKitWindow forKey:@"desktopWindow"];
    CGPoint screenMouse = NSEvent.mouseLocation;
    CGPoint origins[] = {CGPointZero, CGPointMake(205, 241), CGPointMake(screenMouse.x + 20, screenMouse.y + 10)};
    for (size_t i = 0; i < sizeof(origins)/sizeof(*origins); i++) {
        CGPoint origin = origins[i];
        [appKitWindow setFrame:CGRectMake(origin.x, origin.y, 320, 200) display:NO];
        assert(CGPointEqualToPoint(window.mouseLocationOutsideOfEventStream,
                                   CGPointMake(screenMouse.x - origin.x, screenMouse.y - origin.y)));
    }
    DragTestDesktopWindow *desktop = [DragTestDesktopWindow new];
    desktop.window = window;
    desktop.frame = CGRectMake(205, 241, 320, 200);
    [window setValue:desktop forKey:@"desktopWindow"];
    // For a 2× screen, the vendor's missed screen lookup mixes points and
    // pixels at the exact edge. The bridge keeps the original touch position.
    CGPoint top = CGPointMake(462, 744);
    assert(CGPointEqualToPoint([desktop convertEventScreenLocationBackingStore:top], CGPointMake(462, 744)));
    assert(CGPointEqualToPoint([window convertEventScreenLocationBackingStore:CGPointMake(462, 743.5)], CGPointMake(924, 1)));
    assert(CGPointEqualToPoint([window convertEventScreenLocationBackingStore:top], CGPointMake(924, 0)));
    assert(CGPointEqualToPoint([window convertEventScreenLocationBackingStore:CGPointMake(462, 745)], CGPointMake(924, -2)));
    assert(CGPointEqualToPoint([window convertEventScreenLocationBackingStore:CGPointMake(1133, 700)], CGPointMake(2266, 88)));
    assert(CGPointEqualToPoint([window convertEventScreenLocationBackingStore:CGPointMake(-1, -1)], CGPointMake(-2, 1490)));
    window.frame = CGRectMake(0, 0, 320, 200);
    [window setFrameOrigin:CGPointMake(205, 303)];
    assert(CGPointEqualToPoint(desktop.frame.origin, CGPointMake(205, 241)));
    BWView *view = [[BWView alloc] initWithFrame:window.bounds];
    view.testWindow = window;
    [window addSubview:view];
    [view didMoveToWindow];
    TestTouch *touch = [TestTouch new];
    NSSet *touches = [NSSet setWithObject:touch];
    touch.point = CGPointMake(40, 20);
    [view touchesBegan:(id)touches withEvent:nil];
    [view touchesMoved:(id)touches withEvent:nil];
    assert(CGPointEqualToPoint(window.frame.origin, CGPointMake(205, 303)));
    touch.point = CGPointMake(65, 30);
    [view touchesMoved:(id)touches withEvent:nil];
    assert(CGPointEqualToPoint(window.frame.origin, CGPointMake(230, 313)));
    // UIKit now measures in the moved window. The same local offset is a
    // second screen displacement, not a new drag origin.
    [view touchesMoved:(id)touches withEvent:nil];
    assert(CGPointEqualToPoint(window.frame.origin, CGPointMake(255, 323)));
    [view touchesEnded:(id)touches withEvent:nil];
    [view touchesMoved:(id)touches withEvent:nil];
    assert(CGPointEqualToPoint(window.frame.origin, CGPointMake(255, 323)));
    [view touchesBegan:(id)touches withEvent:nil];
    [view touchesCancelled:(id)touches withEvent:nil];
    [view touchesMoved:(id)touches withEvent:nil];
    assert(CGPointEqualToPoint(window.frame.origin, CGPointMake(255, 323)));
    assert(view.mouseDowns + view.mouseUps + view.mouseDrags == 0);
}

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
        testHardware(view);
        testDesktopDrag();
        puts("Direct touch, popup drag, hardware keys and primary/secondary pointer routing passed");
    }
}
