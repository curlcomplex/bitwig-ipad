// AppKit ABI bridge for Bitwig's native window classes. Implemented operations
// delegate to UIKit. Unimplemented selectors retain NSObject's normal exception;
// they must be implemented from observed use, never swallowed as successful calls.
#import <UIKit/UIKit.h>
#import "Trace.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <stdatomic.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Scope receiver-failure diagnostics to classes in the compatibility bridge.
#define BW_TRACE_MISSING_SELECTOR \
- (void)doesNotRecognizeSelector:(SEL)selector { \
    BWCompatibilityTrace("objc", object_getClassName(self), sel_getName(selector), "unrecognized"); \
    [super doesNotRecognizeSelector:selector]; \
} \
+ (void)doesNotRecognizeSelector:(SEL)selector { \
    BWCompatibilityTrace("objc-class", class_getName(self), sel_getName(selector), "unrecognized"); \
    [super doesNotRecognizeSelector:selector]; \
}

NSString *NSEventTrackingRunLoopMode = @"UITrackingRunLoopMode";
NSString *NSModalPanelRunLoopMode = @"NSDefaultRunLoopMode";
NSString *NSPasteboardNameDrag = @"BitwigDragPasteboard";
NSString *NSPasteboardNameGeneral = @"com.apple.UIKit.pboard.general";
NSString *NSWorkspaceDidActivateApplicationNotification = @"UIApplicationDidBecomeActiveNotification";
NSString *NSWorkspaceDidDeactivateApplicationNotification = @"UIApplicationWillResignActiveNotification";
NSString *NSWorkspaceDidWakeNotification = @"UIApplicationWillEnterForegroundNotification";
NSString *NSWorkspaceWillSleepNotification = @"UIApplicationDidEnterBackgroundNotification";
NSString *NSWindowDidBecomeKeyNotification = @"NSWindowDidBecomeKeyNotification";
NSString *NSWindowDidChangeScreenNotification = @"NSWindowDidChangeScreenNotification";
id NSApp;
static NSHashTable *bitwigWindows;
static NSUInteger pressedMouseButtons;
static CGPoint mouseScreenLocation;
static NSUInteger currentModifierFlags;
static UIImage *cursorImage;
static CGPoint cursorHotSpot;
static NSUInteger cursorHideCount;
@class NSView;
static __weak NSView *hoveredView;
static __weak NSView *textInputView;
static BOOL textInputActive;
static atomic_bool escapePressed;

// CoreGraphics key-state import used by Bitwig to detect a local Escape press.
bool CGEventSourceKeyState(int32_t source, uint16_t key) {
    return source == 0 && key == 0x35 && atomic_load_explicit(&escapePressed, memory_order_relaxed);
}

typedef NS_OPTIONS(NSUInteger, BWTouchPhaseMask) {
    BWTouchBegan = 1, BWTouchMoved = 2, BWTouchStationary = 4,
    BWTouchEnded = 8, BWTouchCancelled = 16,
};

@interface NSTouch : NSObject
@property(nonatomic, strong) NSNumber *identity;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic) CGPoint point;
@property(nonatomic) BWTouchPhaseMask phase;
@end

@implementation NSTouch
BW_TRACE_MISSING_SELECTOR
- (NSInteger)type { return 0; } // NSTouchTypeDirect
- (CGPoint)locationInView:(UIView *)view {
    if (!view) return CGPointMake(self.point.x, self.window.bounds.size.height - self.point.y);
    CGPoint local = [view convertPoint:self.point fromView:self.window];
    if ([view respondsToSelector:@selector(isFlipped)] &&
        !((BOOL (*)(id, SEL))objc_msgSend)(view, @selector(isFlipped)))
        local.y = CGRectGetMaxY(view.bounds) - local.y;
    return local;
}
@end

// AppKit recognizers receive NSEvents, independent from UIKit recognizers.
@interface NSGestureRecognizer : NSObject
@property(nonatomic, weak) NSView *view;
@property(nonatomic, weak) id delegate;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic) NSUInteger allowedTouchTypes;
@property(nonatomic) NSInteger state;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)touchesBeganWithEvent:(id)event;
- (void)touchesMovedWithEvent:(id)event;
- (void)touchesEndedWithEvent:(id)event;
- (void)touchesCancelledWithEvent:(id)event;
- (void)reset;
@end

@implementation NSGestureRecognizer
BW_TRACE_MISSING_SELECTOR
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    // BWDirectTouchRecognizer supplies nil target/action and handles events
    // in its own override methods.
    if ((self = [super init])) _enabled = YES;
    return self;
}
- (void)touchesBeganWithEvent:(id)event {}
- (void)touchesMovedWithEvent:(id)event {}
- (void)touchesEndedWithEvent:(id)event {}
- (void)touchesCancelledWithEvent:(id)event {}
- (void)reset { self.state = 0; }
@end

@interface BWTouchRoute : NSObject
@property(nonatomic, strong) NSNumber *identity;
@property(nonatomic, copy) NSArray<NSGestureRecognizer *> *recognizers;
@property(nonatomic) CGPoint point;
@end

@implementation BWTouchRoute
@end

@interface NSObject (BWAppKitTouchDelegate)
- (BOOL)gestureRecognizer:(NSGestureRecognizer *)recognizer shouldReceiveTouch:(NSTouch *)touch;
@end

static CGPoint windowEventLocation(UIWindow *window, CGPoint point) {
    CGPoint screen=[window convertPoint:point toWindow:nil];
    mouseScreenLocation=CGPointMake(screen.x,window.screen.bounds.size.height-screen.y);
    // BWView uses AppKit's bottom-left coordinates and flips them itself.
    return CGPointMake(point.x,window.bounds.size.height-point.y);
}

@interface NSScreen : NSObject
@end
@implementation NSScreen
BW_TRACE_MISSING_SELECTOR
+ (instancetype)mainScreen { static id screen; if (!screen) screen=[self new]; return screen; }
+ (NSArray*)screens { return @[[self mainScreen]]; }
- (CGRect)frame { return UIScreen.mainScreen.bounds; }
- (CGRect)visibleFrame { return self.frame; }
- (CGFloat)backingScaleFactor { return UIScreen.mainScreen.scale; }
- (NSDictionary*)deviceDescription { return @{@"NSScreenNumber":@1}; }
- (NSString*)localizedName { return @"iPad Display"; }
- (NSInteger)maximumFramesPerSecond { return UIScreen.mainScreen.maximumFramesPerSecond; }
@end

@interface NSEvent : NSObject
@property(nonatomic) CGPoint locationInWindow;
@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic) NSInteger type;
@property(nonatomic) NSInteger clickCount;
@property(nonatomic) NSInteger buttonNumber;
@property(nonatomic) NSUInteger modifierFlags;
@property(nonatomic) CGFloat pressure;
@property(nonatomic) NSInteger eventNumber;
@property(nonatomic,strong) id context;
@property(nonatomic) CGFloat deltaX;
@property(nonatomic) CGFloat deltaY;
@property(nonatomic) CGFloat deltaZ;
@property(nonatomic,weak) UIWindow *window;
@property(nonatomic) unsigned short keyCode;
@property(nonatomic) BOOL isARepeat;
@property(nonatomic,copy) NSString *characters;
@property(nonatomic,copy) NSString *charactersIgnoringModifiers;
@property(nonatomic, copy) NSSet<NSTouch *> *directTouches;
@end
@implementation NSEvent
BW_TRACE_MISSING_SELECTOR
+ (instancetype)mouseEventWithType:(NSUInteger)type location:(CGPoint)location modifierFlags:(NSUInteger)flags timestamp:(NSTimeInterval)timestamp windowNumber:(NSInteger)number context:(id)context eventNumber:(NSInteger)eventNumber clickCount:(NSInteger)clickCount pressure:(float)pressure {
    NSEvent *event=[self new];event.type=type;event.locationInWindow=location;event.modifierFlags=flags;event.timestamp=timestamp;
    event.context=context;event.eventNumber=eventNumber;event.clickCount=clickCount;event.pressure=pressure;
    event.buttonNumber=(type==3||type==4||type==7)?1:(type>=25&&type<=27)?2:0;
    for(id window in bitwigWindows.allObjects)if(((NSInteger(*)(id,SEL))objc_msgSend)(window,@selector(windowNumber))==number){event.window=((id(*)(id,SEL))objc_msgSend)(window,@selector(uiWindow));break;}
    return event;
}
- (NSSet<NSTouch *> *)touchesMatchingPhase:(BWTouchPhaseMask)phases inView:(UIView *)view {
    NSMutableSet<NSTouch *> *matches = [NSMutableSet new];
    for (NSTouch *touch in self.directTouches)
        if ((touch.phase & phases) && (!view || view.window == touch.window)) [matches addObject:touch];
    return matches;
}
+ (NSUInteger)pressedMouseButtons { return pressedMouseButtons; }
+ (CGPoint)mouseLocation { return mouseScreenLocation; }
+ (NSUInteger)modifierFlags { return currentModifierFlags; }
- (NSInteger)windowNumber { return ((NSInteger(*)(id,SEL))objc_msgSend)(self.window,@selector(windowNumber)); }
@end
// AppKit retains the last dispatched event, including between callbacks.
// Keep the actual UIKit-adapted event so callers see its type and coordinates.
static NSEvent *lastApplicationEvent;
static __weak id draggingDesktopWindow;
static CGPoint dragStartScreen,dragStartOrigin;
static BOOL BWHandleDraggingEvent(NSEvent *event, BOOL cancelled);
static void deliverEvent(id receiver,SEL selector,NSEvent *event) {
    lastApplicationEvent=event;
    if(BWHandleDraggingEvent(event,NO))return;
    if(draggingDesktopWindow&&(event.type==6||event.type==2)){
        if(event.type==6){
            CGPoint screen=((CGPoint(*)(id,SEL,CGPoint))objc_msgSend)(draggingDesktopWindow,@selector(convertPointToScreen:),event.locationInWindow);
            CGPoint origin=CGPointMake(dragStartOrigin.x+screen.x-dragStartScreen.x,dragStartOrigin.y+screen.y-dragStartScreen.y);
            ((void(*)(id,SEL,CGPoint))objc_msgSend)(draggingDesktopWindow,@selector(setFrameOrigin:),origin);
        }else draggingDesktopWindow=nil;
        return;
    }
    ((void(*)(id,SEL,id))objc_msgSend)(receiver,selector,event);
}
@interface NSTrackingArea : NSObject
@property(nonatomic) CGRect rect;
@property(nonatomic) NSUInteger options;
@property(nonatomic,weak) id owner;
@property(nonatomic,strong) NSDictionary *userInfo;
@end
@implementation NSTrackingArea
- (id)initWithRect:(CGRect)rect options:(NSUInteger)options owner:(id)owner userInfo:(NSDictionary*)info {
    if((self=[super init])){_rect=rect;_options=options;_owner=owner;_userInfo=info;}return self;
}
@end
@interface NSView : UIView <UIPointerInteractionDelegate,UIKeyInput>
@property(nonatomic) BOOL wantsLayer;
@property(nonatomic) NSInteger layerContentsRedrawPolicy;
@property(nonatomic) NSInteger layerContentsPlacement;
@property(nonatomic,strong) NSMutableArray<NSTrackingArea*> *tracking;
@property(nonatomic,strong) UIHoverGestureRecognizer *hover;
@property(nonatomic,strong) UIPointerInteraction *pointerInteraction;
@property(nonatomic,strong) UIImageView *cursorOverlay;
@property(nonatomic) CGPoint hoverLocation;
@property(nonatomic, strong) NSMutableArray<NSGestureRecognizer *> *appKitRecognizers;
@property(nonatomic, strong) NSMapTable<UITouch *, BWTouchRoute *> *touchRoutes;
@property(nonatomic, strong) UITouch *mouseTouch;
@property(nonatomic, strong) NSMutableSet<UITouch *> *endingTouches;
- (void)cancelActiveContacts;
- (void)updateCursor;
@end
@implementation NSView
BW_TRACE_MISSING_SELECTOR
// AppKit's base live-resize notifications have no effect on an ordinary
// view. The UIKit scene still owns the actual layout and geometry updates.
- (void)viewWillStartLiveResize {}
- (void)viewDidEndLiveResize {}
+ (Class)layerClass { return CAMetalLayer.class; }
- (void)setWantsLayer:(BOOL)value {
    _wantsLayer=value;
    if(!value)return;
    CALayer *configured=[self makeBackingLayer];
    CAMetalLayer *layer=(CAMetalLayer*)self.layer;
    if(configured!=layer && [configured isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *metal=(CAMetalLayer*)configured;
        layer.device=metal.device;layer.pixelFormat=metal.pixelFormat;
        layer.framebufferOnly=metal.framebufferOnly;layer.backgroundColor=metal.backgroundColor;
        layer.needsDisplayOnBoundsChange=metal.needsDisplayOnBoundsChange;
    }
    layer.contentsScale=UIScreen.mainScreen.scale;
    layer.drawableSize=CGSizeMake(self.bounds.size.width*layer.contentsScale,self.bounds.size.height*layer.contentsScale);
}
- (void)setLayerContentsRedrawPolicy:(NSInteger)policy { _layerContentsRedrawPolicy=policy;self.layer.needsDisplayOnBoundsChange=(policy==2); }
- (void)setLayerContentsPlacement:(NSInteger)placement { _layerContentsPlacement=placement;self.layer.contentsGravity=(placement==11?kCAGravityTopLeft:kCAGravityResize); }
- (id)makeBackingLayer { return self.layer; }
- (void)setFrameSize:(CGSize)size { CGRect frame=self.frame; frame.size=size; self.frame=frame; }
- (void)setFrameOrigin:(CGPoint)origin { CGRect frame=self.frame; frame.origin=origin; self.frame=frame; }
- (CGRect)convertRectToBacking:(CGRect)rect { CGFloat scale=self.window.screen.scale ?: UIScreen.mainScreen.scale; return CGRectApplyAffineTransform(rect,CGAffineTransformMakeScale(scale,scale)); }
- (CGRect)convertRectFromBacking:(CGRect)rect { CGFloat scale=self.window.screen.scale ?: UIScreen.mainScreen.scale; return CGRectApplyAffineTransform(rect,CGAffineTransformMakeScale(1/scale,1/scale)); }
- (CGPoint)convertPointToBacking:(CGPoint)point { CGFloat scale=self.window.screen.scale ?: UIScreen.mainScreen.scale; return CGPointMake(point.x*scale,point.y*scale); }
- (CGPoint)convertPointFromBacking:(CGPoint)point { CGFloat scale=self.window.screen.scale ?: UIScreen.mainScreen.scale; return CGPointMake(point.x/scale,point.y/scale); }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return self.canBecomeFirstResponder; }
- (void)viewDidMoveToWindow {}
- (void)viewDidChangeBackingProperties {}
- (void)willMoveToWindow:(UIWindow *)newWindow {
    if (self.window && self.window != newWindow) {
        [self cancelActiveContacts];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:UISceneWillDeactivateNotification
                                                    object:self.window.windowScene];
    }
    [super willMoveToWindow:newWindow];
}

- (void)sceneWillDeactivate:(NSNotification *)notification {
    [self cancelActiveContacts];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window.windowScene)
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sceneWillDeactivate:)
                                                   name:UISceneWillDeactivateNotification object:self.window.windowScene];
    // The vendor constructor attaches this only on macOS 27. Attach the
    // original recognizer when our UIKit bridge can supply its touch events.
    Class bitwigView = NSClassFromString(@"BWView");
    Class directRecognizer = NSClassFromString(@"BWDirectTouchRecognizer");
    if (self.window && bitwigView && directRecognizer && [self isKindOfClass:bitwigView]) {
        BOOL attached = NO;
        for (NSGestureRecognizer *recognizer in self.appKitRecognizers)
            if ([recognizer isKindOfClass:directRecognizer]) attached = YES;
        if (!attached)
            [self addGestureRecognizer:(id)[directRecognizer new]];
    }
    [self viewDidMoveToWindow];
    [self viewDidChangeBackingProperties];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // UIKit resizes via bounds/layout, whereas AppKit invokes setFrameSize:.
    // Notify Bitwig so its Metal drawable uses the final point size and scale.
    if(self.window)[self viewDidChangeBackingProperties];
}
- (void)displayIfNeeded { [self layoutIfNeeded]; [self.layer displayIfNeeded]; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { if(!self.window.canBecomeKeyWindow)return NO;textInputView=self;return [super becomeFirstResponder]; }
- (UIView*)inputView { static UIView *empty; if(!empty)empty=[[UIView alloc] initWithFrame:CGRectZero];return textInputActive?nil:empty; }
- (UIView*)inputAccessoryView {
    if(!textInputActive)return nil;
    UIToolbar *toolbar=[[UIToolbar alloc] initWithFrame:CGRectMake(0,0,320,44)];
    toolbar.items=@[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissTextKeyboard)]];
    return toolbar;
}
- (void)dismissTextKeyboard { [self resignFirstResponder]; }
- (BOOL)hasText { return textInputActive; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (void)insertText:(NSString*)text {
    if([self respondsToSelector:@selector(insertText:replacementRange:)])
        ((void(*)(id,SEL,id,NSRange))objc_msgSend)(self,@selector(insertText:replacementRange:),text,NSMakeRange(NSNotFound,0));
}
- (void)deleteBackward {
    NSEvent *event=[NSEvent new];event.window=self.window;event.keyCode=51;event.characters=@"\177";event.charactersIgnoringModifiers=@"\177";event.timestamp=NSProcessInfo.processInfo.systemUptime;event.type=10;
    if([self respondsToSelector:@selector(keyDown:)])deliverEvent(self,@selector(keyDown:),event);
    NSEvent *up=[NSEvent new];up.window=self.window;up.keyCode=51;up.characters=@"\177";up.charactersIgnoringModifiers=@"\177";up.timestamp=NSProcessInfo.processInfo.systemUptime;up.type=11;
    if([self respondsToSelector:@selector(keyUp:)])deliverEvent(self,@selector(keyUp:),up);
}
- (id)inputContext { return textInputActive?((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"NSTextInputContext"),@selector(currentInputContext)):nil; }
- (NSArray*)trackingAreas { return self.tracking.copy ?: @[]; }
- (void)addTrackingArea:(NSTrackingArea*)area {
    if(!self.tracking)self.tracking=[NSMutableArray new];[self.tracking addObject:area];
    if(!self.hover){self.hover=[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(handleHover:)];[self addGestureRecognizer:self.hover];self.pointerInteraction=[[UIPointerInteraction alloc] initWithDelegate:self];[self addInteraction:self.pointerInteraction];}
}
- (void)removeTrackingArea:(NSTrackingArea*)area { [self.tracking removeObject:area]; }
- (void)updateCursor {
    if(!self.cursorOverlay){self.cursorOverlay=[UIImageView new];self.cursorOverlay.userInteractionEnabled=NO;[self addSubview:self.cursorOverlay];}
    self.cursorOverlay.image=cursorImage;
    self.cursorOverlay.frame=CGRectMake(self.hoverLocation.x-cursorHotSpot.x,self.hoverLocation.y-cursorHotSpot.y,cursorImage.size.width,cursorImage.size.height);
    self.cursorOverlay.hidden=(hoveredView!=self||!cursorImage||cursorHideCount>0);
    [self.pointerInteraction invalidate];
}
- (UIPointerStyle*)pointerInteraction:(UIPointerInteraction*)interaction styleForRegion:(UIPointerRegion*)region {
    return (cursorImage||cursorHideCount>0)?UIPointerStyle.hiddenPointerStyle:UIPointerStyle.systemPointerStyle;
}
- (void)handleHover:(UIHoverGestureRecognizer*)gesture {
    currentModifierFlags=gesture.modifierFlags;
    hoveredView=(gesture.state==UIGestureRecognizerStateEnded||gesture.state==UIGestureRecognizerStateCancelled)?nil:self;
    self.hoverLocation=[gesture locationInView:self];[self updateCursor];
    SEL selector=gesture.state==UIGestureRecognizerStateBegan?@selector(mouseEntered:):gesture.state==UIGestureRecognizerStateEnded?@selector(mouseExited:):@selector(mouseMoved:);
    NSEvent *event=[NSEvent new];event.window=self.window;event.locationInWindow=windowEventLocation(self.window,[gesture locationInView:self.window]);event.timestamp=NSProcessInfo.processInfo.systemUptime;
    event.type=gesture.state==UIGestureRecognizerStateBegan?8:gesture.state==UIGestureRecognizerStateEnded?9:5;
    event.modifierFlags=currentModifierFlags;
    for(NSTrackingArea *area in self.tracking)if([area.owner respondsToSelector:selector])deliverEvent(area.owner,selector,event);
}
- (void)sendTouch:(UITouch*)touch selector:(SEL)selector type:(NSInteger)type {
    if(type==1)pressedMouseButtons|=1;
    else if(type==2)pressedMouseButtons&=~(NSUInteger)1;
    if(![self respondsToSelector:selector])return;
    CGPoint current=[touch locationInView:self.window],previous=[touch previousLocationInView:self.window];
    NSEvent *event=[NSEvent new];event.window=self.window;event.locationInWindow=windowEventLocation(self.window,current);event.timestamp=touch.timestamp;event.clickCount=touch.tapCount;event.type=type;event.pressure=touch.force;
    event.deltaX=current.x-previous.x;event.deltaY=current.y-previous.y;
    event.modifierFlags=currentModifierFlags;
    if(type==1||type==2)fprintf(stdout,"[UIKit input] type=%ld window=(%.1f,%.1f) event=(%.1f,%.1f) windowSize=(%.1f,%.1f) viewSize=(%.1f,%.1f)\n",(long)type,current.x,current.y,event.locationInWindow.x,event.locationInWindow.y,self.window.bounds.size.width,self.window.bounds.size.height,self.bounds.size.width,self.bounds.size.height);
    deliverEvent(self,selector,event);
}
- (void)addGestureRecognizer:(UIGestureRecognizer *)recognizer {
    if (![(id)recognizer isKindOfClass:NSGestureRecognizer.class]) {
        [super addGestureRecognizer:recognizer];
        return;
    }
    NSGestureRecognizer *appKit = (id)recognizer;
    if (appKit.view == self) return;
    [appKit.view removeGestureRecognizer:recognizer];
    if (!self.appKitRecognizers) self.appKitRecognizers = [NSMutableArray new];
    [self.appKitRecognizers addObject:appKit];
    appKit.view = self;
    self.multipleTouchEnabled = YES;
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--native-touch-trace"]) {
        fprintf(stdout, "[UIKit direct] attached %s to %s\n",
                class_getName(appKit.class), class_getName(self.class));
        fflush(stdout);
    }
}

- (void)removeGestureRecognizer:(UIGestureRecognizer *)recognizer {
    if (![(id)recognizer isKindOfClass:NSGestureRecognizer.class]) {
        [super removeGestureRecognizer:recognizer];
        return;
    }
    NSGestureRecognizer *appKit = (id)recognizer;
    if (appKit.view != self) return;
    [self.appKitRecognizers removeObjectIdenticalTo:appKit];
    // Reset releases the original recognizer's outstanding contacts. Keep
    // those UIKit routes closed until their terminal events arrive.
    [appKit reset];
    appKit.view = nil;
    for (BWTouchRoute *route in self.touchRoutes.objectEnumerator) {
        NSMutableArray *remaining = [route.recognizers mutableCopy];
        [remaining removeObjectIdenticalTo:appKit];
        route.recognizers = remaining;
    }
    self.multipleTouchEnabled = self.appKitRecognizers.count > 0;
}

- (NSTouch *)snapshotForRoute:(BWTouchRoute *)route phase:(BWTouchPhaseMask)phase {
    NSTouch *touch = [NSTouch new];
    touch.identity = route.identity;
    touch.window = self.window;
    touch.point = route.point;
    touch.phase = phase;
    return touch;
}

- (void)beginContacts:(NSSet<UITouch *> *)touches {
    static NSUInteger nextIdentity;
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeDirect && self.appKitRecognizers.count) {
            BWTouchRoute *route = [BWTouchRoute new];
            route.identity = @(++nextIdentity);
            route.point = [touch locationInView:self.window];
            NSTouch *snapshot = [self snapshotForRoute:route phase:BWTouchBegan];
            NSMutableArray *recipients = [NSMutableArray new];
            for (NSGestureRecognizer *recognizer in self.appKitRecognizers.copy) {
                if (!recognizer.enabled || !(recognizer.allowedTouchTypes & 1)) continue;
                id delegate = recognizer.delegate;
                if (![delegate respondsToSelector:@selector(gestureRecognizer:shouldReceiveTouch:)] ||
                    [delegate gestureRecognizer:recognizer shouldReceiveTouch:snapshot])
                    [recipients addObject:recognizer];
            }
            if (recipients.count) {
                route.recognizers = recipients;
                if (!self.touchRoutes)
                    self.touchRoutes = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory |
                                        NSPointerFunctionsObjectPointerPersonality
                                                             valueOptions:NSPointerFunctionsStrongMemory];
                [self.touchRoutes setObject:route forKey:touch];
                continue;
            }
        }
        if (!self.mouseTouch) {
            self.mouseTouch = touch;
            [self sendTouch:touch selector:@selector(mouseMoved:) type:5];
            [self sendTouch:touch selector:@selector(mouseDown:) type:1];
        }
    }
}

- (void)dispatchContacts:(NSSet<UITouch *> *)changed event:(UIEvent *)uiEvent phase:(BWTouchPhaseMask)phase {
    BOOL terminal = phase == BWTouchEnded || phase == BWTouchCancelled;
    if (terminal) {
        if (!self.endingTouches) self.endingTouches = [NSMutableSet new];
        [self.endingTouches unionSet:changed];
    }
    for (UITouch *touch in changed) {
        BWTouchRoute *route = [self.touchRoutes objectForKey:touch];
        if (route) route.point = [touch locationInView:self.window];
    }
    for (NSGestureRecognizer *recognizer in self.appKitRecognizers.copy) {
        NSMutableSet *snapshots = [NSMutableSet new];
        NSTouch *firstChanged = nil;
        UITouch *firstUIKitTouch = nil;
        NSUInteger remaining = 0;
        for (UITouch *touch in self.touchRoutes.keyEnumerator) {
            BWTouchRoute *route = [self.touchRoutes objectForKey:touch];
            if (![route.recognizers containsObject:recognizer]) continue;
            BOOL updated = [changed containsObject:touch];
            if (!updated && [self.endingTouches containsObject:touch]) continue;
            NSTouch *snapshot = [self snapshotForRoute:route phase:updated ? phase : BWTouchStationary];
            [snapshots addObject:snapshot];
            if (!terminal || !updated) remaining++;
            if (!updated) continue;
            if (!firstChanged) {
                firstChanged = snapshot;
                firstUIKitTouch = touch;
            }
        }
        if (!firstChanged) continue;
        NSEvent *event = [NSEvent new];
        event.type = 29; // NSEventTypeGesture
        event.directTouches = snapshots;
        event.window = self.window;
        event.timestamp = uiEvent ? uiEvent.timestamp : firstUIKitTouch.timestamp;
        event.modifierFlags = currentModifierFlags;
        event.locationInWindow = [firstChanged locationInView:nil];
        lastApplicationEvent = event;
        switch (phase) {
            case BWTouchBegan: [recognizer touchesBeganWithEvent:event]; break;
            case BWTouchMoved: [recognizer touchesMovedWithEvent:event]; break;
            case BWTouchEnded: [recognizer touchesEndedWithEvent:event]; break;
            case BWTouchCancelled: [recognizer touchesCancelledWithEvent:event]; break;
            case BWTouchStationary: break;
        }
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--native-touch-trace"]) {
            for (NSTouch *touch in snapshots) {
                if (touch.phase == BWTouchStationary) continue;
                fprintf(stdout, "[UIKit direct] recognizer=%s phase=%lu id=%lu active=%lu point=(%.1f,%.1f) state=%ld\n",
                        class_getName(recognizer.class), (unsigned long)phase, touch.identity.unsignedLongValue,
                        (unsigned long)remaining, touch.point.x, touch.point.y, (long)recognizer.state);
            }
            fflush(stdout);
        }
        if (terminal && remaining == 0) [recognizer reset];
    }
    if (terminal) {
        for (UITouch *touch in changed) [self.touchRoutes removeObjectForKey:touch];
        [self.endingTouches minusSet:changed];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    currentModifierFlags = event.modifierFlags;
    [self becomeFirstResponder];
    [self beginContacts:touches];
    [self dispatchContacts:touches event:event phase:BWTouchBegan];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    currentModifierFlags = event.modifierFlags;
    [self dispatchContacts:touches event:event phase:BWTouchMoved];
    if (self.mouseTouch && [touches containsObject:self.mouseTouch])
        [self sendTouch:self.mouseTouch selector:@selector(mouseDragged:) type:6];
}

- (void)finishContacts:(NSSet<UITouch *> *)touches event:(UIEvent *)event cancelled:(BOOL)cancelled {
    currentModifierFlags = event.modifierFlags;
    UITouch *mouse = self.mouseTouch;
    if (mouse && [touches containsObject:mouse]) self.mouseTouch = nil;
    else mouse = nil;
    [self dispatchContacts:touches event:event phase:cancelled ? BWTouchCancelled : BWTouchEnded];
    if (mouse) {
        if (!cancelled || !BWHandleDraggingEvent(lastApplicationEvent, YES))
            [self sendTouch:mouse selector:@selector(mouseUp:) type:2];
        else
            pressedMouseButtons &= ~(NSUInteger)1;
    }
}

- (void)cancelActiveContacts {
    NSMutableSet<UITouch *> *active = [NSMutableSet setWithArray:self.touchRoutes.keyEnumerator.allObjects ?: @[]];
    if (self.mouseTouch) [active addObject:self.mouseTouch];
    if (self.endingTouches) [active minusSet:self.endingTouches];
    if (active.count) [self finishContacts:active event:nil cancelled:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self finishContacts:touches event:event cancelled:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self finishContacts:touches event:event cancelled:YES];
}

- (void)setEscapeForPresses:(NSSet<UIPress *> *)presses down:(BOOL)down {
    for (UIPress *press in presses) {
        if (press.key.keyCode == UIKeyboardHIDUsageKeyboardEscape)
            atomic_store_explicit(&escapePressed, down, memory_order_relaxed);
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self setEscapeForPresses:presses down:YES];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self setEscapeForPresses:presses down:NO];
    [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self setEscapeForPresses:presses down:NO];
    [super pressesCancelled:presses withEvent:event];
}

@end

void BWUIKitSetTextInputActive(BOOL active) {
    dispatch_async(dispatch_get_main_queue(),^{
        textInputActive=active;
        [textInputView reloadInputViews];
    });
}

@interface NSTextInputContext : NSObject @end
@implementation NSTextInputContext
+ (id)currentInputContext { static id context;static dispatch_once_t once;dispatch_once(&once,^{context=[self new];});return textInputActive?context:nil; }
- (BOOL)handleEvent:(NSEvent*)event {
    if(event.type!=10||event.modifierFlags&((1u<<18)|(1u<<20)))return NO;
    if(!event.characters.length||[event.characters rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return NO;
    [textInputView insertText:event.characters];return YES;
}
- (void)invalidateCharacterCoordinates { [textInputView setNeedsLayout]; }
- (void)discardMarkedText { if([textInputView respondsToSelector:@selector(unmarkText)])((void(*)(id,SEL))objc_msgSend)(textInputView,@selector(unmarkText)); }
@end

@interface BWHostViewController : UIViewController @end
@implementation BWHostViewController
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

@interface BWUIKitWindow : UIWindow
@property(nonatomic,weak) id desktopWindow;
@end
@implementation BWUIKitWindow
- (void)layoutSubviews {
    [super layoutSubviews];
    id desktop=self.desktopWindow;
    if (desktop && (((NSUInteger(*)(id,SEL))objc_msgSend)(desktop,@selector(styleMask))&8)) {
        CGRect bounds=self.windowScene.coordinateSpace.bounds;
        if (!CGRectEqualToRect([desktop frame],bounds))
            ((void(*)(id,SEL,CGRect,BOOL))objc_msgSend)(desktop,@selector(setFrame:display:),bounds,YES);
    }
}
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector]||[self.desktopWindow respondsToSelector:selector]; }
- (BOOL)canBecomeKeyWindow { return self.desktopWindow?((BOOL(*)(id,SEL))objc_msgSend)(self.desktopWindow,@selector(canBecomeKeyWindow)):[super canBecomeKeyWindow]; }
- (void)notifyKeyState:(BOOL)key {
    id desktop=self.desktopWindow;if(!desktop)return;
    NSString *name=key?NSWindowDidBecomeKeyNotification:@"NSWindowDidResignKeyNotification";
    NSNotification *notification=[NSNotification notificationWithName:name object:desktop];
    [NSNotificationCenter.defaultCenter postNotification:notification];
    id delegate=[desktop delegate];SEL selector=key?@selector(windowDidBecomeKey:):@selector(windowDidResignKey:);
    if([delegate respondsToSelector:selector])((void(*)(id,SEL,id))objc_msgSend)(delegate,selector,notification);
}
- (void)becomeKeyWindow {
    [super becomeKeyWindow];
    // BWWindow finishes assigning its Java peer after makeKeyWindow during init.
    dispatch_async(dispatch_get_main_queue(),^{if(self.isKeyWindow)[self notifyKeyState:YES];});
}
- (void)resignKeyWindow {
    atomic_store_explicit(&escapePressed, false, memory_order_relaxed);
    [super resignKeyWindow];
    dispatch_async(dispatch_get_main_queue(),^{if(!self.isKeyWindow)[self notifyKeyState:NO];});
}
- (id)forwardingTargetForSelector:(SEL)selector {
    if([self.desktopWindow respondsToSelector:selector])return self.desktopWindow;
    return [super forwardingTargetForSelector:selector];
}
@end
@interface NSWindow : NSObject
@property(nonatomic,strong) UIWindow *uiWindow;
@property(nonatomic,strong) NSView *contentView;
@property(nonatomic,weak) id delegate;
@property(nonatomic,copy) NSString *title;
@property(nonatomic) BOOL releasedWhenClosed;
@property(nonatomic) BOOL acceptsMouseMovedEvents;
@property(nonatomic) NSUInteger collectionBehavior;
@property(nonatomic) NSUInteger styleMask;
@property(nonatomic) NSInteger level;
@property(nonatomic) CGSize minSize;
@property(nonatomic) CGSize maxSize;
@property(nonatomic) NSInteger windowNumber;
@property(nonatomic) BOOL miniaturized;
@property(nonatomic) CGRect frameBeforeZoom;
@property(nonatomic) CGRect desktopFrame;
// Desktop policy hints retained for callers. UIKit owns scene movement,
// capture policy and background hiding; these hints cannot override it.
@property(nonatomic) BOOL canHide;
@property(nonatomic) BOOL preservesContentDuringLiveResize;
@property(nonatomic) BOOL movableByWindowBackground;
@property(nonatomic, getter=isMovable) BOOL movable;
@property(nonatomic) BOOL titlebarAppearsTransparent;
@property(nonatomic) NSInteger titleVisibility;
@property(nonatomic) NSUInteger sharingType;
@property(nonatomic,copy) NSArray *registeredDraggedTypes;
@end
@implementation NSWindow
BW_TRACE_MISSING_SELECTOR
- (id)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer screen:(NSScreen*)screen {
    return [self initWithContentRect:rect styleMask:style backing:backing defer:defer];
}
- (id)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer {
    if ((self=[super init])) {
        NSAssert(NSThread.isMainThread,@"Window creation must run on the UIKit thread");
        UIWindowScene *scene=(UIWindowScene*)UIApplication.sharedApplication.connectedScenes.anyObject;
        BWUIKitWindow *window=[[BWUIKitWindow alloc] initWithWindowScene:scene];
        window.desktopWindow=self;_uiWindow=window;
        if(style&8)rect=scene.coordinateSpace.bounds;
        _desktopFrame=rect;
        _uiWindow.frame=CGRectMake(rect.origin.x,scene.coordinateSpace.bounds.size.height-CGRectGetMaxY(rect),rect.size.width,rect.size.height);
        _uiWindow.rootViewController=[BWHostViewController new];
        _styleMask=style;
        _movable=YES;
        static NSInteger nextNumber=1;_windowNumber=nextNumber++;
        _maxSize=CGSizeMake(CGFLOAT_MAX,CGFLOAT_MAX);
        if(!bitwigWindows)bitwigWindows=[NSHashTable weakObjectsHashTable];
        [bitwigWindows addObject:self];
    }
    return self;
}
- (void)setContentView:(NSView*)view { _contentView=view; self.uiWindow.rootViewController.view=view; }
- (void)setAllowsConcurrentViewDrawing:(BOOL)allow { self.uiWindow.layer.drawsAsynchronously=allow; }
- (BOOL)allowsConcurrentViewDrawing { return self.uiWindow.layer.drawsAsynchronously; }
- (void)setBackgroundColor:(id)color {
    CGColorRef cg=((CGColorRef(*)(id,SEL))objc_msgSend)(color,@selector(CGColor));
    self.uiWindow.backgroundColor=[UIColor colorWithCGColor:cg];
}
- (void)setOpaque:(BOOL)opaque { self.uiWindow.opaque=opaque; }
- (BOOL)isOpaque { return self.uiWindow.opaque; }
- (void)setHasShadow:(BOOL)shadow { self.uiWindow.layer.shadowOpacity=shadow?0.3:0;self.uiWindow.layer.shadowRadius=8; }
- (BOOL)canBecomeKeyWindow { return (self.styleMask&9)!=0; }
- (BOOL)canBecomeMainWindow { return (self.styleMask&9)!=0; }
- (void)setLevel:(NSInteger)level { _level=level;self.uiWindow.windowLevel=UIWindowLevelNormal+level; }
- (void)makeKeyWindow { [self.uiWindow makeKeyWindow]; }
- (NSEvent*)nextEventMatchingMask:(NSUInteger)mask untilDate:(NSDate*)date inMode:(NSString*)mode dequeue:(BOOL)dequeue {
    @synchronized(NSApp){
        NSMutableArray *queue=[NSApp valueForKey:@"postedEvents"];
        for(NSUInteger i=0;i<queue.count;i++){
            NSEvent *event=queue[i];
            if(event.window==self.uiWindow&&event.type<64&&(mask&(1ull<<event.type))){if(dequeue)[queue removeObjectAtIndex:i];return event;}
        }
    }return nil;
}
- (void)registerForDraggedTypes:(NSArray*)types { self.registeredDraggedTypes=types; } // Drop event delivery is not implemented yet.
- (CGRect)frame { return self.desktopFrame; }
- (CGRect)constrainFrameRect:(CGRect)frame toScreen:(NSScreen *)screen {
    CGRect visible = (screen ?: self.screen).visibleFrame;
    if (screen == nil || screen == self.screen) {
        UIWindowScene *scene = self.uiWindow.windowScene;
        if (scene) visible = scene.coordinateSpace.bounds;
    }
    if (CGRectIsEmpty(visible)) return frame;

    // AppKit constrains the top edge in desktop (bottom-left) coordinates.
    CGFloat top = CGRectGetMaxY(frame);
    if (self.styleMask & 8) frame.size.height = MIN(frame.size.height, CGRectGetHeight(visible));
    CGFloat minimumTop = CGRectGetMinY(visible) + MIN(frame.size.height, CGRectGetHeight(visible));
    frame.origin.y = MIN(MAX(top, minimumTop), CGRectGetMaxY(visible)) - frame.size.height;
    return frame;
}
- (CGSize)contentMinSize { return self.minSize; }
- (void)setContentMinSize:(CGSize)size { self.minSize=size;self.uiWindow.windowScene.sizeRestrictions.minimumSize=size; }
- (CGSize)contentMaxSize { return self.maxSize; }
- (void)setContentMaxSize:(CGSize)size { self.maxSize=size;self.uiWindow.windowScene.sizeRestrictions.maximumSize=size; }
- (void)setFrame:(CGRect)frame display:(BOOL)display {
    if(self.styleMask&8)frame=self.uiWindow.windowScene.coordinateSpace.bounds;
    CGRect previous=self.desktopFrame;
    self.desktopFrame=frame;
    self.uiWindow.frame=CGRectMake(frame.origin.x,self.uiWindow.windowScene.coordinateSpace.bounds.size.height-CGRectGetMaxY(frame),frame.size.width,frame.size.height);
    if(display) [self.uiWindow layoutIfNeeded];
    if(!CGPointEqualToPoint(previous.origin,frame.origin)&&[self.delegate respondsToSelector:@selector(windowDidMove:)])
        ((void(*)(id,SEL,id))objc_msgSend)(self.delegate,@selector(windowDidMove:),[NSNotification notificationWithName:@"NSWindowDidMoveNotification" object:self]);
    if(!CGSizeEqualToSize(previous.size,frame.size)&&[self.delegate respondsToSelector:@selector(windowDidResize:)])
        ((void(*)(id,SEL,id))objc_msgSend)(self.delegate,@selector(windowDidResize:),[NSNotification notificationWithName:@"NSWindowDidResizeNotification" object:self]);
}
- (void)setContentSize:(CGSize)size { CGRect frame=self.frame; frame.size=size; [self setFrame:frame display:YES]; }
- (BOOL)isMovable { return _movable && !(self.styleMask & 8); }
- (void)setFrameOrigin:(CGPoint)origin { CGRect frame=self.frame;frame.origin=origin;[self setFrame:frame display:YES]; }
- (void)setFrameTopLeftPoint:(CGPoint)point { CGRect frame=self.frame;frame.origin=CGPointMake(point.x,point.y-frame.size.height);[self setFrame:frame display:YES]; }
- (NSScreen*)screen { return NSScreen.mainScreen; }
- (CGFloat)backingScaleFactor { return self.uiWindow.screen.scale; }
- (CGRect)convertRectToBacking:(CGRect)rect { CGFloat scale=self.backingScaleFactor;return CGRectApplyAffineTransform(rect,CGAffineTransformMakeScale(scale,scale)); }
- (CGRect)convertRectFromBacking:(CGRect)rect { CGFloat scale=self.backingScaleFactor;return CGRectApplyAffineTransform(rect,CGAffineTransformMakeScale(1/scale,1/scale)); }
- (void)makeKeyAndOrderFront:(id)sender { BOOL wasKey=self.uiWindow.isKeyWindow;[self.uiWindow makeKeyAndVisible];if(wasKey)[(BWUIKitWindow*)self.uiWindow notifyKeyState:YES]; }
- (void)orderFront:(id)sender { self.uiWindow.hidden=NO; }
- (void)orderOut:(id)sender { self.uiWindow.hidden=YES; }
- (void)close { [self.contentView cancelActiveContacts]; self.uiWindow.hidden=YES; self.uiWindow=nil; [bitwigWindows removeObject:self]; }
- (BOOL)isVisible { return self.uiWindow && !self.uiWindow.hidden; }
- (BOOL)isMiniaturized { return self.miniaturized; }
- (BOOL)isZoomed { return CGRectEqualToRect(self.frame,self.uiWindow.windowScene.coordinateSpace.bounds); }
- (void)zoom:(id)sender {
    if(self.isZoomed&&!CGRectIsEmpty(self.frameBeforeZoom))[self setFrame:self.frameBeforeZoom display:YES];
    else {self.frameBeforeZoom=self.frame;[self setFrame:self.uiWindow.windowScene.coordinateSpace.bounds display:YES];}
}
- (void)miniaturize:(id)sender { self.miniaturized=YES;self.uiWindow.hidden=YES; }
- (void)deminiaturize:(id)sender { self.miniaturized=NO;[self.uiWindow makeKeyAndVisible]; }
- (BOOL)isKeyWindow { return self.uiWindow.keyWindow; }
- (BOOL)makeFirstResponder:(UIResponder*)responder { return [responder becomeFirstResponder]; }
- (CGRect)contentRectForFrameRect:(CGRect)rect { return rect; }
- (CGRect)frameRectForContentRect:(CGRect)rect { return rect; }
- (CGPoint)convertPointToScreen:(CGPoint)point { return CGPointMake(self.frame.origin.x+point.x,self.frame.origin.y+point.y); }
- (CGPoint)convertPointFromScreen:(CGPoint)point { return CGPointMake(point.x-self.frame.origin.x,point.y-self.frame.origin.y); }
- (CGRect)convertRectToScreen:(CGRect)rect { rect.origin=[self convertPointToScreen:rect.origin];return rect; }
- (CGRect)convertRectFromScreen:(CGRect)rect { rect.origin=[self convertPointFromScreen:rect.origin];return rect; }
- (CGPoint)convertBaseToScreen:(CGPoint)point { return [self convertPointToScreen:point]; }
- (CGPoint)convertScreenToBase:(CGPoint)point { return [self convertPointFromScreen:point]; }
- (void)performWindowDragWithEvent:(NSEvent*)event {
    draggingDesktopWindow=self;dragStartOrigin=self.frame.origin;dragStartScreen=[self convertPointToScreen:event.locationInWindow];
}
@end
@interface NSPanel : NSWindow @end
@implementation NSPanel @end

@interface NSApplication : NSObject
@property(nonatomic,weak) id delegate;
@property(nonatomic,strong) id mainMenu;
@property(nonatomic,strong) id servicesMenu;
@property(nonatomic,strong) id windowsMenu;
@property(nonatomic) BOOL finishedLaunching;
@property(nonatomic,strong) NSMutableArray<NSEvent*> *postedEvents;
@end
@implementation NSApplication
BW_TRACE_MISSING_SELECTOR
+ (instancetype)sharedApplication { if(!NSApp) NSApp=[self new]; return NSApp; }
- (NSEvent*)currentEvent { return lastApplicationEvent; }
- (NSEvent*)nextEventMatchingMask:(NSUInteger)mask untilDate:(NSDate*)date inMode:(NSString*)mode dequeue:(BOOL)dequeue {
    // UIKit dispatches hardware events directly; only explicitly posted desktop
    // events belong to this queue. Bitwig polls it with the current date.
    @synchronized(self){for(NSUInteger i=0;i<self.postedEvents.count;i++){
        NSEvent *event=self.postedEvents[i];if(event.type<64&&(mask&(1ull<<event.type))){if(dequeue)[self.postedEvents removeObjectAtIndex:i];return event;}
    }}return nil;
}
- (void)sendEvent:(NSEvent*)event {
    SEL selector=NULL;
    switch(event.type){
        case 1:selector=@selector(mouseDown:);break;case 2:selector=@selector(mouseUp:);break;
        case 3:selector=@selector(rightMouseDown:);break;case 4:selector=@selector(rightMouseUp:);break;
        case 5:selector=@selector(mouseMoved:);break;case 6:selector=@selector(mouseDragged:);break;
        case 7:selector=@selector(rightMouseDragged:);break;case 10:selector=@selector(keyDown:);break;
        case 11:selector=@selector(keyUp:);break;case 12:selector=@selector(flagsChanged:);break;
        case 22:selector=@selector(scrollWheel:);break;
    }
    id view=event.window.rootViewController.view;
    if(selector&&[view respondsToSelector:selector])deliverEvent(view,selector,event);
}
- (void)postEvent:(NSEvent*)event atStart:(BOOL)atStart {
    if(!event)return;
    @synchronized(self){
        if(!self.postedEvents)self.postedEvents=[NSMutableArray new];
        if(atStart)[self.postedEvents insertObject:event atIndex:0];else[self.postedEvents addObject:event];
    }
    dispatch_async(dispatch_get_main_queue(),^{
        NSEvent *next=nil;
        @synchronized(self){if(self.postedEvents.count){next=self.postedEvents.firstObject;[self.postedEvents removeObjectAtIndex:0];}}
        if(next)[self sendEvent:next];
    });
}
- (BOOL)isActive { return UIApplication.sharedApplication.applicationState==UIApplicationStateActive; }
- (BOOL)isRunning { return YES; }
- (NSArray*)windows { return bitwigWindows.allObjects ?: @[]; }
- (NSWindow*)keyWindow { for(NSWindow *window in self.windows)if(window.isKeyWindow)return window;return nil; }
- (NSWindow*)mainWindow { return self.keyWindow; }
- (NSWindow*)windowWithWindowNumber:(NSInteger)number { for(NSWindow *window in self.windows)if(window.windowNumber==number)return window;return nil; }
- (void)activateIgnoringOtherApps:(BOOL)ignore {
    NSWindow *window=self.keyWindow ?: self.windows.firstObject;
    if(window) [window makeKeyAndOrderFront:self];
    else for(UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes)
        if([scene isKindOfClass:UIWindowScene.class]&&scene.activationState==UISceneActivationStateForegroundActive)
            [scene.windows.firstObject makeKeyAndVisible];
}
- (void)finishLaunching {
    if(self.finishedLaunching)return; self.finishedLaunching=YES;
    for(NSString *name in @[@"NSApplicationWillFinishLaunchingNotification",@"NSApplicationDidFinishLaunchingNotification"]) {
        NSNotification *notification=[NSNotification notificationWithName:name object:self];
        SEL selector=NSSelectorFromString([name containsString:@"Will"]?@"applicationWillFinishLaunching:":@"applicationDidFinishLaunching:");
        if([self.delegate respondsToSelector:selector]) ((void(*)(id,SEL,id))objc_msgSend)(self.delegate,selector,notification);
        [NSNotificationCenter.defaultCenter postNotification:notification];
    }
}
- (void)run { NSAssert(NSThread.isMainThread,@"Application loop must run on UIKit thread");[self finishLaunching];[[NSRunLoop currentRunLoop] run]; }
- (BOOL)setActivationPolicy:(NSInteger)policy { return policy==0; }
@end

// UIKit already exports NSColor; re-export that class rather than registering a
// duplicate Objective-C class with undefined runtime selection.

@interface NSImage : NSObject
@property(nonatomic,strong) UIImage *image;
@end
@implementation NSImage
BW_TRACE_MISSING_SELECTOR
- (id)initWithSize:(CGSize)size { if((self=[super init])){UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:size];_image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){}];}return self; }
- (id)initWithContentsOfFile:(NSString*)path { if((self=[super init])) _image=[UIImage imageWithContentsOfFile:path]; return self; }
- (id)initWithData:(NSData*)data { if((self=[super init])) _image=[UIImage imageWithData:data]; return self; }
- (CGSize)size { return self.image.size; }
@end
@interface NSCursor : NSObject
@property(nonatomic,strong) NSImage *image;
@property(nonatomic) CGPoint hotSpot;
@end
@implementation NSCursor
BW_TRACE_MISSING_SELECTOR
- (id)initWithImage:(NSImage*)image hotSpot:(CGPoint)point { if((self=[super init])){_image=image;_hotSpot=point;}return self; }
+ (instancetype)arrowCursor { static NSCursor *cursor;static dispatch_once_t once;dispatch_once(&once,^{cursor=[self new];});return cursor; }
- (void)set { cursorImage=self.image.image;cursorHotSpot=self.hotSpot;[hoveredView updateCursor]; }
+ (void)hide { cursorHideCount++;[hoveredView updateCursor]; }
+ (void)unhide { if(cursorHideCount)cursorHideCount--;[hoveredView updateCursor]; }
@end
@interface NSImageView : UIImageView @end
@implementation NSImageView @end

@protocol BWDeclaredPasteboard <NSObject>
- (NSArray<NSString *> *)declaredTypes;
- (id)declaredGeneration;
- (NSData *)dataForType:(NSString *)type;
- (NSString *)stringForType:(NSString *)type;
@end

@interface NSPasteboardItem : NSObject
@property(nonatomic,weak) id<BWDeclaredPasteboard> declaredBoard;
@property(nonatomic,strong) id declaredGeneration;
@property(nonatomic) BOOL followsDeclaredTypes;
@property(nonatomic,strong) NSMutableDictionary<NSString*,id> *representations;
@property(nonatomic,strong) UIPasteboard *source;
@property(nonatomic) NSUInteger sourceIndex;
@end
@implementation NSPasteboardItem
BW_TRACE_MISSING_SELECTOR
- (id)init { if((self=[super init]))_representations=[NSMutableDictionary new];return self; }
- (NSArray<NSString*>*)types {
    if(self.declaredGeneration != self.declaredBoard.declaredGeneration)return @[];
    if(self.followsDeclaredTypes)return self.declaredBoard.declaredTypes;
    if(self.source)return [self.source pasteboardTypesForItemSet:[NSIndexSet indexSetWithIndex:self.sourceIndex]].firstObject?:@[];
    return self.representations.allKeys;
}
- (NSData*)dataForType:(NSString*)type {
    if(self.declaredGeneration != self.declaredBoard.declaredGeneration)return nil;
    if(self.followsDeclaredTypes)
        return [self.declaredBoard.declaredTypes containsObject:type] ? [self.declaredBoard dataForType:type] : nil;
    if(self.source)return [self.source dataForPasteboardType:type inItemSet:[NSIndexSet indexSetWithIndex:self.sourceIndex]].firstObject;
    id value=self.representations[type];
    if([value isKindOfClass:NSData.class])return value;
    if([value isKindOfClass:NSString.class])return [value dataUsingEncoding:NSUTF8StringEncoding];
    return nil;
}
- (NSString*)stringForType:(NSString*)type {
    if(self.declaredGeneration != self.declaredBoard.declaredGeneration)return nil;
    if(self.followsDeclaredTypes)
        return [self.declaredBoard.declaredTypes containsObject:type] ? [self.declaredBoard stringForType:type] : nil;
    id value=self.source?[self.source valuesForPasteboardType:type inItemSet:[NSIndexSet indexSetWithIndex:self.sourceIndex]].firstObject:self.representations[type];
    if([value isKindOfClass:NSString.class])return value;
    if([value isKindOfClass:NSData.class])return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    return nil;
}
- (BOOL)setData:(NSData*)data forType:(NSString*)type { if(!data||!type)return NO;self.representations[type]=data;return YES; }
- (BOOL)setString:(NSString*)string forType:(NSString*)type { if(!string||!type)return NO;self.representations[type]=string;return YES; }
@end

@interface NSPasteboard : NSObject <BWDeclaredPasteboard>
@property(nonatomic,strong) UIPasteboard *pasteboard;
@property(nonatomic,copy) NSString *logicalName;
@property(nonatomic,copy) NSArray<NSString *> *declaredTypes;
@property(nonatomic,strong) id declaredGeneration;
@property(nonatomic,weak) id declaredOwner;
@property(nonatomic,strong) NSMutableDictionary<NSString *, id> *declaredValues;
@property(nonatomic,strong) NSMutableSet<NSString *> *providingTypes;
@property(nonatomic,strong) NSMutableArray<NSPasteboardItem *> *declaredAdditionalItems;
@property(nonatomic) NSInteger backingCountAdjustment;
@end
@implementation NSPasteboard
BW_TRACE_MISSING_SELECTOR
+ (instancetype)generalPasteboard { return [self pasteboardWithName:NSPasteboardNameGeneral]; }
+ (instancetype)pasteboardWithName:(NSString*)name {
    static NSMutableDictionary *boards; if(!boards)boards=[NSMutableDictionary new];
    NSPasteboard *board=boards[name];
    if(!board){
        board=[self new];board.logicalName=name;
        // Desktop Bitwig polls the general board during startup and on a timer.
        // On iPad, even this polling can request cross-application paste access.
        // Keep this prototype's clipboard app-local; never read the system board.
        // External paste must later enter through an explicit UIKit paste action.
        NSString *localName=[NSString stringWithFormat:@"%@.bitwig.%@",NSBundle.mainBundle.bundleIdentifier,name];
        board.pasteboard=[UIPasteboard pasteboardWithName:localName create:YES];
        boards[name]=board;
    }
    return board;
}
- (NSString*)name { return self.logicalName; }
- (NSArray<NSString*>*)types {
    if(!self.declaredTypes)return self.pasteboard.pasteboardTypes;
    NSMutableOrderedSet *types = [NSMutableOrderedSet orderedSetWithArray:self.declaredTypes];
    for(NSPasteboardItem *item in self.declaredAdditionalItems)
        [types addObjectsFromArray:item.types];
    return types.array;
}
- (NSArray<NSPasteboardItem*>*)pasteboardItems {
    NSMutableArray *items=[NSMutableArray new];
    // Bitwig polls item types. Keep content lazy so polling does not request
    // cross-application paste permission before the user actually pastes.
    if(self.declaredTypes.count) {
        NSPasteboardItem *first=[NSPasteboardItem new];
        first.declaredBoard=self;
        first.declaredGeneration=self.declaredGeneration;
        first.followsDeclaredTypes=YES;
        [items addObject:first];
    }
    if(self.declaredGeneration) {
        [items addObjectsFromArray:self.declaredAdditionalItems];
        return items;
    }
    for(NSUInteger index=0;index<self.pasteboard.numberOfItems;index++){
        NSPasteboardItem *item=[NSPasteboardItem new];
        item.source=self.pasteboard;item.sourceIndex=index;
        [items addObject:item];
    }
    return items;
}
- (NSInteger)changeCount { return self.pasteboard.changeCount - self.backingCountAdjustment; }
- (void)resetBackingItems {
    NSInteger before = self.pasteboard.changeCount;
    self.pasteboard.items = @[];
    self.backingCountAdjustment += self.pasteboard.changeCount - before - 1;
}
- (void)notifyPreviousOwner:(id)owner {
    SEL changed = @selector(pasteboardChangedOwner:);
    if(owner != self.declaredOwner && [owner respondsToSelector:changed]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void(*)(id,SEL,id))objc_msgSend)(owner,changed,self);
        });
    }
}
- (NSInteger)clearContents {
    id previous = self.declaredOwner;
    self.declaredOwner = nil;
    self.declaredTypes = nil;
    self.declaredGeneration = nil;
    self.declaredValues = nil;
    self.providingTypes = nil;
    self.declaredAdditionalItems = nil;
    [self resetBackingItems];
    [self notifyPreviousOwner:previous];
    return self.changeCount;
}
- (NSInteger)declareTypes:(NSArray<NSString *> *)types owner:(id)owner {
    BWCompatibilityTrace("bridge", "NSPasteboard", "declareTypes:owner:",
                         owner ? "declared_with_owner" : "declared_eager");
    id previous = self.declaredOwner;
    [self resetBackingItems];
    self.declaredTypes = [NSOrderedSet orderedSetWithArray:types ?: @[]].array;
    self.declaredGeneration = [NSObject new];
    self.declaredOwner = owner;
    self.declaredValues = [NSMutableDictionary new];
    self.providingTypes = [NSMutableSet new];
    self.declaredAdditionalItems = [NSMutableArray new];
    [self notifyPreviousOwner:previous];
    return self.changeCount;
}
- (BOOL)setDeclaredValue:(id)value forType:(NSString *)type {
    if(![self.declaredTypes containsObject:type])
        self.declaredTypes = [self.declaredTypes arrayByAddingObject:type];
    self.declaredValues[type] = value;
    return YES;
}
- (id)declaredValueForType:(NSString *)type {
    if(!type || ![self.declaredTypes containsObject:type]) return nil;
    id value = self.declaredValues[type];
    id owner = self.declaredOwner;
    SEL provide = @selector(pasteboard:provideDataForType:);
    NSMutableSet *requests = self.providingTypes;
    if(!value && ![requests containsObject:type] && [owner respondsToSelector:provide]) {
        [requests addObject:type];
        @try {
            ((void(*)(id,SEL,id,id))objc_msgSend)(owner,provide,self,type);
        } @finally {
            [requests removeObject:type];
        }
        if(requests != self.providingTypes)return nil;
        value = self.declaredValues[type];
    }
    return value;
}
- (BOOL)setString:(NSString*)text forType:(NSString*)type {
    if(!text||!type)return NO;
    if(self.declaredTypes)return [self setDeclaredValue:text forType:type];
    [self.pasteboard setValue:text forPasteboardType:type];return YES;
}
- (NSString*)stringForType:(NSString*)type {
    if(self.declaredGeneration && ![self.declaredTypes containsObject:type]) {
        for(NSPasteboardItem *item in self.declaredAdditionalItems)
            if([item.types containsObject:type]) return [item stringForType:type];
        return nil;
    }
    id value=[self.declaredTypes containsObject:type]?[self declaredValueForType:type]:[self.pasteboard valueForPasteboardType:type];
    if([value isKindOfClass:NSString.class])return value;
    if([value isKindOfClass:NSData.class])return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    return nil;
}
- (NSData*)dataForType:(NSString*)type {
    if(self.declaredGeneration && ![self.declaredTypes containsObject:type]) {
        for(NSPasteboardItem *item in self.declaredAdditionalItems)
            if([item.types containsObject:type]) return [item dataForType:type];
        return nil;
    }
    if(![self.declaredTypes containsObject:type])return [self.pasteboard dataForPasteboardType:type];
    id value=[self declaredValueForType:type];
    if([value isKindOfClass:NSData.class])return value;
    if([value isKindOfClass:NSString.class])return [value dataUsingEncoding:NSUTF8StringEncoding];
    return nil;
}
- (BOOL)setData:(NSData*)data forType:(NSString*)type {
    if(!data||!type)return NO;
    if(self.declaredTypes)return [self setDeclaredValue:data forType:type];
    [self.pasteboard setData:data forPasteboardType:type];return YES;
}
- (BOOL)writeObjects:(NSArray<NSPasteboardItem*>*)objects {
    NSMutableArray *items=[NSMutableArray new];
    for(NSPasteboardItem *item in objects){
        NSMutableDictionary *values=[NSMutableDictionary new];
        for(NSString *type in item.types){NSData *data=[item dataForType:type];if(data)values[type]=data;}
        [items addObject:values];
    }
    if(self.declaredGeneration) {
        for(NSDictionary *values in items) {
            NSPasteboardItem *item = [NSPasteboardItem new];
            item.declaredBoard = self;
            item.declaredGeneration = self.declaredGeneration;
            [item.representations addEntriesFromDictionary:values];
            [self.declaredAdditionalItems addObject:item];
        }
        return YES;
    }
    [self.pasteboard addItems:items];
    return YES;
}
@end

@interface NSRunningApplication : NSObject @end
@implementation NSRunningApplication
+ (instancetype)currentApplication { static id application;static dispatch_once_t once;dispatch_once(&once,^{application=[self new];});return application; }
- (pid_t)processIdentifier { return NSProcessInfo.processInfo.processIdentifier; }
- (NSString*)bundleIdentifier { return NSBundle.mainBundle.bundleIdentifier; }
- (NSURL*)bundleURL { return NSBundle.mainBundle.bundleURL; }
- (NSURL*)executableURL { return NSBundle.mainBundle.executableURL; }
- (NSString*)localizedName { return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]?:[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"]; }
- (BOOL)isActive { return UIApplication.sharedApplication.applicationState==UIApplicationStateActive; }
- (BOOL)isTerminated { return NO; } // This wrapper represents the executing process.
@end

@interface NSWorkspace : NSObject @end
@implementation NSWorkspace
BW_TRACE_MISSING_SELECTOR
+ (instancetype)sharedWorkspace { static id workspace; if(!workspace) workspace=[self new]; return workspace; }
- (NSNotificationCenter*)notificationCenter { return NSNotificationCenter.defaultCenter; }
- (NSRunningApplication*)frontmostApplication {
    // iPadOS does not expose the identity of other foreground applications.
    // Return our actual process only while it owns foreground activation.
    return UIApplication.sharedApplication.applicationState==UIApplicationStateActive?[NSRunningApplication currentApplication]:nil;
}
@end

@class NSMenu;
@interface NSMenuItem : NSObject
@property(nonatomic,copy) NSString *title;
@property(nonatomic) SEL action;
@property(nonatomic,weak) id target;
@property(nonatomic,copy) NSString *keyEquivalent;
@property(nonatomic) NSUInteger keyEquivalentModifierMask;
@property(nonatomic,strong) NSMenu *submenu;
@property(nonatomic,strong) id representedObject;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL hidden;
@property(nonatomic) BOOL separatorItem;
@property(nonatomic) NSInteger state;
@property(nonatomic) NSInteger tag;
@end
@implementation NSMenuItem
BW_TRACE_MISSING_SELECTOR
- (id)initWithTitle:(NSString*)title action:(SEL)action keyEquivalent:(NSString*)key {
    if((self=[super init])) {_title=[title copy];_action=action;_keyEquivalent=[key copy];_enabled=YES;}return self;
}
+ (instancetype)separatorItem { NSMenuItem *item=[[self alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];item.separatorItem=YES;return item; }
- (BOOL)isSeparatorItem { return self.separatorItem; }
@end
@interface NSMenu : NSObject
@property(nonatomic,copy) NSString *title;
@property(nonatomic,strong) NSMutableArray<NSMenuItem*> *items;
@property(nonatomic) BOOL autoenablesItems;
@property(nonatomic,weak) id delegate;
- (UIMenu*)uiMenu;
@end
@implementation NSMenu
BW_TRACE_MISSING_SELECTOR
- (id)initWithTitle:(NSString*)title { if((self=[super init])){_title=[title copy];_items=[NSMutableArray new];}return self; }
- (NSArray*)itemArray { return self.items.copy; }
- (NSInteger)numberOfItems { return self.items.count; }
- (void)addItem:(NSMenuItem*)item { [self.items addObject:item];[UIMenuSystem.mainSystem setNeedsRebuild]; }
- (NSMenuItem*)addItemWithTitle:(NSString*)title action:(SEL)action keyEquivalent:(NSString*)key { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];[self addItem:item];return item; }
- (void)insertItem:(NSMenuItem*)item atIndex:(NSInteger)index { [self.items insertObject:item atIndex:index];[UIMenuSystem.mainSystem setNeedsRebuild]; }
- (void)removeItem:(NSMenuItem*)item { [self.items removeObject:item];[UIMenuSystem.mainSystem setNeedsRebuild]; }
- (void)removeItemAtIndex:(NSInteger)index { [self.items removeObjectAtIndex:index];[UIMenuSystem.mainSystem setNeedsRebuild]; }
- (void)removeAllItems { [self.items removeAllObjects];[UIMenuSystem.mainSystem setNeedsRebuild]; }
- (NSMenuItem*)itemAtIndex:(NSInteger)index { return self.items[index]; }
- (NSMenuItem*)itemWithTag:(NSInteger)tag { for(NSMenuItem *item in self.items)if(item.tag==tag)return item;return nil; }
- (NSInteger)indexOfItem:(NSMenuItem*)item { return [self.items indexOfObject:item]; }
- (void)setSubmenu:(NSMenu*)submenu forItem:(NSMenuItem*)item { item.submenu=submenu;[UIMenuSystem.mainSystem setNeedsRebuild]; }
- (void)update { [UIMenuSystem.mainSystem setNeedsRebuild]; }
- (UIMenu*)uiMenu {
    NSMutableArray<UIMenuElement*> *children=[NSMutableArray new];
    for(NSMenuItem *item in self.items) {
        if(item.hidden||item.separatorItem)continue;
        if(item.submenu) { [children addObject:[item.submenu uiMenu]];continue; }
        UIAction *action=[UIAction actionWithTitle:item.title?:@"" image:nil identifier:nil handler:^(UIAction *action){
            id target=item.target;
            if(!target&&[NSApp respondsToSelector:item.action])target=NSApp;
            if(!target&&[[NSApp delegate] respondsToSelector:item.action])target=[NSApp delegate];
            if(target&&item.action) ((void(*)(id,SEL,id))objc_msgSend)(target,item.action,item);
        }];
        action.attributes=item.enabled?0:UIMenuElementAttributesDisabled;
        action.state=item.state==1?UIMenuElementStateOn:UIMenuElementStateOff;
        [children addObject:action];
    }
    return [UIMenu menuWithTitle:self.title?:@"" children:children];
}
@end
void BWUIKitBuildMenu(id<UIMenuBuilder> builder) {
    NSMenu *menu=[NSApp mainMenu];if(menu)[builder insertChildMenu:[menu uiMenu] atEndOfMenuForIdentifier:UIMenuRoot];
}

// Explicitly enabled development input, confined to our Bitwig windows. This
// exercises the original mouse handlers; it is not a hardware-touch test.
void BWUIKitPollTestInput(void) {
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *path=[documents stringByAppendingPathComponent:@"native-ui-command.json"];
    NSData *data=[NSData dataWithContentsOfFile:path];if(!data)return;
    NSDictionary *command=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![command isKindOfClass:NSDictionary.class])return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil]; // Consume once, before dispatch.
    NSMutableDictionary *result=[@{@"id":command[@"id"]?:@"",@"ok":@NO} mutableCopy];
    NSMutableArray *windows=[NSMutableArray new];NSWindow *target=nil;
    for(NSWindow *window in bitwigWindows){
        if(window.uiWindow.hidden)continue;
        CGRect frame=window.uiWindow.frame;
        [windows addObject:@{@"title":window.title?:@"",@"key":@(window.uiWindow.isKeyWindow),@"frame":@[@(frame.origin.x),@(frame.origin.y),@(frame.size.width),@(frame.size.height)]}];
        if(window.uiWindow.isKeyWindow)target=window;
    }
    if([command[@"action"] isEqual:@"click"]){
        CGPoint point=CGPointMake([command[@"x"] doubleValue],[command[@"y"] doubleValue]);
        NSWindow *hit=nil;
        for(NSWindow *window in bitwigWindows){
            if(window.uiWindow.hidden||!CGRectContainsPoint(window.uiWindow.frame,point))continue;
            if(!hit||window.uiWindow.windowLevel>hit.uiWindow.windowLevel)hit=window;
        }
        if(hit)target=hit;
    }
    result[@"windows"]=windows;
    result[@"text_input_active"]=@(textInputActive);
    result[@"text_first_responder"]=@(textInputView.isFirstResponder);
    if(textInputActive&&[textInputView respondsToSelector:@selector(selectedRange)]){
        NSRange selected=((NSRange(*)(id,SEL))objc_msgSend)(textInputView,@selector(selectedRange));
        result[@"text_selection"]=@[@(selected.location),@(selected.length)];
    }
    result[@"delete_key_translation"]=@(((NSUInteger(*)(id,SEL,NSUInteger,id))objc_msgSend)(NSObject.class,@selector(translateKeyCode:withCharacters:),51,@"\177"));
    if([command[@"action"] isEqual:@"inspect"])result[@"ok"]=@YES;
    else if([command[@"action"] isEqual:@"engine"]){
        Class coordinator=NSClassFromString(@"NativeEngineCoordinator");
        SEL start=NSSelectorFromString(@"startWithArguments:environment:completion:");
        if([coordinator respondsToSelector:start]){
            void (^started)(int)=^(int pid){fprintf(stdout,"[engine-test] started pid=%d\n",pid);};
            ((void(*)(id,SEL,id,id,id))objc_msgSend)(coordinator,start,@[[command[@"port"] stringValue]?:@"0"],@{},started);
            result[@"ok"]=@YES;
        }
    }
    else if([command[@"action"] isEqual:@"click"]&&target&&[(target.title?:@"") isEqual:command[@"title"]]){
        CGPoint screen=CGPointMake([command[@"x"] doubleValue],[command[@"y"] doubleValue]);
        CGPoint point=[target.uiWindow convertPoint:screen fromWindow:nil];
        NSView *view=target.contentView;
        if(CGRectContainsPoint(target.uiWindow.bounds,point)&&[view respondsToSelector:@selector(mouseDown:)]&&[view respondsToSelector:@selector(mouseUp:)]){
            [view becomeFirstResponder];currentModifierFlags=0;
            NSEvent *event=[NSEvent new];event.window=target.uiWindow;event.locationInWindow=windowEventLocation(target.uiWindow,point);event.timestamp=NSProcessInfo.processInfo.systemUptime;event.clickCount=MAX(1,[command[@"count"] integerValue]);
            event.type=5;if([view respondsToSelector:@selector(mouseMoved:)])deliverEvent(view,@selector(mouseMoved:),event);
            pressedMouseButtons=1;event.type=1;deliverEvent(view,@selector(mouseDown:),event);
            // Let the Java event loop observe the pressed state before release.
            // Keep distinct immutable event objects, as with real UIKit touches.
            NSTimeInterval hold=MAX(0.1,[command[@"hold"] doubleValue]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(hold*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                NSEvent *up=[NSEvent new];up.window=event.window;up.locationInWindow=event.locationInWindow;up.timestamp=NSProcessInfo.processInfo.systemUptime;up.clickCount=event.clickCount;up.type=2;
                pressedMouseButtons=0;deliverEvent(view,@selector(mouseUp:),up);
                result[@"ok"]=@YES;
                [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"native-ui-result.json"] atomically:YES];
            });
            return;
        }
    }
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [encoded writeToFile:[documents stringByAppendingPathComponent:@"native-ui-result.json"] atomically:YES];
}

// Save selection remains unsupported. The open panel shares this preference
// with AppKit's save panel, although Files owns iOS directory-management UI.
@interface NSSavePanel : NSPanel
@property(nonatomic) BOOL canCreateDirectories;
@end
@implementation NSSavePanel
- (instancetype)init {
    if((self=[super init])) _canCreateDirectories=YES;
    return self;
}
@end


// Native asynchronous Files picker. Imported files live in the shared container
// so both the frontend and the sandboxed audio engine can read them.
@interface NSOpenPanel : NSSavePanel <UIDocumentPickerDelegate>
@property BOOL allowsMultipleSelection,canChooseDirectories,canChooseFiles,allowsOtherFileTypes,canSelectHiddenExtension,floatingPanel;
@property(copy) NSArray<NSString*> *allowedFileTypes;
@property(copy) NSString *nameFieldStringValue;
@property(strong) NSURL *directoryURL;
@property(copy) NSArray<NSURL*> *URLs;
@property(copy) void (^completion)(NSInteger);
@property(strong) UIDocumentPickerViewController *picker;
@end
@implementation NSOpenPanel
- (instancetype)init {
    if((self=[super init])) {
        self.canCreateDirectories=NO;
        _canChooseFiles=YES;
    }
    return self;
}
+ (id)openPanel { return [self new]; }
- (NSURL*)URL { return self.URLs.firstObject; }
- (void)beginWithCompletionHandler:(void(^)(NSInteger))completion {
    BWCompatibilityTrace("bridge", "NSOpenPanel", "beginWithCompletionHandler:", "opened");
    BWCompatibilityTrace("bridge", "NSOpenPanel", "canCreateDirectories",
                         self.canCreateDirectories ? "requested_true_files_controls_ui" : "requested_false_files_controls_ui");
    NSLog(@"Native file picker opened files=%d directories=%d multiple=%d",self.canChooseFiles,self.canChooseDirectories,self.allowsMultipleSelection);
    self.completion=completion;
    NSMutableArray<UTType*> *types=[NSMutableArray new];
    if(self.canChooseDirectories)[types addObject:UTTypeFolder];
    if(self.canChooseFiles){
        if(self.allowsOtherFileTypes||!self.allowedFileTypes.count)[types addObject:UTTypeItem];
        else for(NSString *extension in self.allowedFileTypes){UTType *type=[UTType typeWithFilenameExtension:extension];if(type)[types addObject:type];}
    }
    if(!types.count)[types addObject:UTTypeItem];
    self.picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:!self.canChooseDirectories];
    self.picker.delegate=self;self.picker.allowsMultipleSelection=self.allowsMultipleSelection;self.picker.title=self.title;
    if(self.directoryURL.isFileURL)self.picker.directoryURL=self.directoryURL;
    NSWindow *window=[NSApp keyWindow];UIViewController *presenter=window.uiWindow.rootViewController;
    while(presenter.presentedViewController)presenter=presenter.presentedViewController;
    if(!presenter){[self finishWithURLs:@[]];return;}
    [presenter presentViewController:self.picker animated:YES completion:nil];
}
- (void)finishWithURLs:(NSArray<NSURL*>*)urls {
    BWCompatibilityTrace("bridge", "NSOpenPanel", "finishWithURLs:", urls.count ? "selected" : "no_selection");
    NSLog(@"Native file picker completed count=%lu",(unsigned long)urls.count);
    self.URLs=urls;void(^completion)(NSInteger)=self.completion;self.completion=nil;
    self.picker.delegate=nil;self.picker=nil;
    if(completion)completion(urls.count?1:0);
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller { [self finishWithURLs:@[]]; }
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    NSLog(@"Native file picker selected count=%lu",(unsigned long)urls.count);
    NSMutableArray *imported=[NSMutableArray new];NSError *error=nil;
    NSURL *group=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.org.example.bitwigipad"];
    if(!group)group=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *destination=[[group URLByAppendingPathComponent:@"BitwigUser/Imports"] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:&error];
    for(NSURL *url in urls){
        BOOL scoped=[url startAccessingSecurityScopedResource];
        NSURL *copy=[destination URLByAppendingPathComponent:url.lastPathComponent];
        if(!error&&[NSFileManager.defaultManager copyItemAtURL:url toURL:copy error:&error])[imported addObject:copy];
        if(scoped)[url stopAccessingSecurityScopedResource];
        if(error)break;
    }
    if(error){
        NSLog(@"Native file import failed: %@",error);
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not import file" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        dispatch_async(dispatch_get_main_queue(),^{NSWindow *window=[NSApp keyWindow];[window.uiWindow.rootViewController presentViewController:alert animated:YES completion:nil];});
        [self finishWithURLs:@[]];return;
    }
    [self finishWithURLs:imported];
}
@end

BOOL NSPointInRect(CGPoint point, CGRect rect) { return CGRectContainsPoint(rect,point); }
BOOL NSApplicationLoad(void) { [NSApplication sharedApplication]; return YES; }
CFTypeRef CFMakeCollectable(CFTypeRef value) { return value; } // GC is disabled on iOS.

// In-application drag sessions follow the original AppKit destination protocol.
// UIKit touch events continue driving the gesture; no system clipboard reads.
@interface NSDraggingItem : NSObject
@property(nonatomic,strong) id item;
@property(nonatomic) CGRect draggingFrame;
@property(nonatomic,strong) id imageContents;
@end
@implementation NSDraggingItem
BW_TRACE_MISSING_SELECTOR
- (id)initWithPasteboardWriter:(id)writer { if((self=[super init]))_item=writer;return self; }
- (void)setDraggingFrame:(CGRect)frame contents:(id)contents { self.draggingFrame=frame;self.imageContents=contents; }
@end
@interface NSDraggingSession : NSObject
@property(nonatomic,strong) NSArray *items;
@property(nonatomic,strong) id draggingSource;
@property(nonatomic,strong) NSPasteboard *draggingPasteboard;
@property(nonatomic,strong) NSWindow *draggingDestinationWindow;
@property(nonatomic) CGPoint draggingLocation;
@property(nonatomic) NSInteger draggingSequenceNumber;
@property(nonatomic) NSUInteger draggingSourceOperationMask;
@property(nonatomic) NSUInteger operation;
@property(nonatomic) BOOL animatesToStartingPositionsOnCancelOrFail;
@property(nonatomic) NSInteger draggingFormation;
@end
@implementation NSDraggingSession
BW_TRACE_MISSING_SELECTOR
- (NSInteger)numberOfValidItemsForDrop { return self.items.count; }
@end
static NSDraggingSession *activeDrag;
static void dragNotify(id target,SEL selector,id session){if([target respondsToSelector:selector])((void(*)(id,SEL,id))objc_msgSend)(target,selector,session);}
static NSUInteger dragOperation(id target,SEL selector,id session){return [target respondsToSelector:selector]?((NSUInteger(*)(id,SEL,id))objc_msgSend)(target,selector,session):0;}
static BOOL BWHandleDraggingEvent(NSEvent *event,BOOL cancelled){
    NSDraggingSession *session=activeDrag;
    if(!session||(!cancelled&&event.type!=6&&event.type!=2))return NO;
    CGPoint screen=mouseScreenLocation;
    NSWindow *destination=nil;
    if(!cancelled)for(NSWindow *candidate in bitwigWindows.allObjects){
        if(candidate.isVisible&&CGRectContainsPoint(candidate.frame,screen)&&candidate.registeredDraggedTypes.count&&
           (!destination||candidate.level>destination.level||candidate.isKeyWindow))destination=candidate;
    }
    if(session.draggingDestinationWindow!=destination){
        dragNotify(session.draggingDestinationWindow,@selector(draggingExited:),session);
        session.draggingDestinationWindow=destination;
        session.draggingLocation=[destination convertPointFromScreen:screen];
        session.operation=dragOperation(destination,@selector(draggingEntered:),session);
    }else if(destination){
        session.draggingLocation=[destination convertPointFromScreen:screen];
        session.operation=dragOperation(destination,@selector(draggingUpdated:),session);
    }
    if([session.draggingSource respondsToSelector:@selector(draggingSession:movedToPoint:)])
        ((void(*)(id,SEL,id,CGPoint))objc_msgSend)(session.draggingSource,@selector(draggingSession:movedToPoint:),session,screen);
    if(cancelled||event.type==2){
        NSUInteger result=0;
        if(!cancelled&&destination&&session.operation&&
           dragOperation(destination,@selector(prepareForDragOperation:),session)&&
           dragOperation(destination,@selector(performDragOperation:),session)){
            result=session.operation;dragNotify(destination,@selector(concludeDragOperation:),session);
        }
        dragNotify(destination,@selector(draggingEnded:),session);
        activeDrag=nil;pressedMouseButtons&=~(NSUInteger)1;
        if([session.draggingSource respondsToSelector:@selector(draggingSession:endedAtPoint:operation:)])
            ((void(*)(id,SEL,id,CGPoint,NSUInteger))objc_msgSend)(session.draggingSource,@selector(draggingSession:endedAtPoint:operation:),session,screen,result);
        NSLog(@"Native drag ended operation=%lu cancelled=%d",(unsigned long)result,cancelled);
    }
    return YES;
}
@implementation NSView (NativeDragging)
- (NSDraggingSession*)beginDraggingSessionWithItems:(NSArray*)items event:(NSEvent*)event source:(id)source {
    if(activeDrag)BWHandleDraggingEvent(event,YES);
    NSDraggingSession *session=[NSDraggingSession new];session.items=items;session.draggingSource=source;
    static NSInteger sequence;session.draggingSequenceNumber=++sequence;
    session.draggingPasteboard=[NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
    [session.draggingPasteboard clearContents];
    NSMutableArray *writers=[NSMutableArray new];for(NSDraggingItem *item in items)if(item.item)[writers addObject:item.item];
    [session.draggingPasteboard writeObjects:writers];
    session.draggingSourceOperationMask=[source respondsToSelector:@selector(draggingSession:sourceOperationMaskForDraggingContext:)]?
        ((NSUInteger(*)(id,SEL,id,NSInteger))objc_msgSend)(source,@selector(draggingSession:sourceOperationMaskForDraggingContext:),session,1):1;
    activeDrag=session;
    if([source respondsToSelector:@selector(draggingSession:willBeginAtPoint:)])
        ((void(*)(id,SEL,id,CGPoint))objc_msgSend)(source,@selector(draggingSession:willBeginAtPoint:),session,mouseScreenLocation);
    NSLog(@"Native drag began items=%lu",(unsigned long)items.count);
    // The Java request can arrive after a very short gesture has already ended.
    dispatch_async(dispatch_get_main_queue(),^{if(activeDrag==session){NSEvent *update=[NSEvent new];update.type=pressedMouseButtons?6:2;BWHandleDraggingEvent(update,NO);}});
    return session;
}
@end
