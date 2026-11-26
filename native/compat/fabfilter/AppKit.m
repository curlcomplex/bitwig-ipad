#import <UIKit/UIKit.h>

NSString *const NSApplicationWillResignActiveNotification = @"UIApplicationWillResignActiveNotification";
NSString *const NSDeviceRGBColorSpace = @"NSDeviceRGBColorSpace";
NSString *const NSNibOwner = @"NSNibOwner";
NSString *const NSNibTopLevelObjects = @"NSNibTopLevelObjects";
NSString *const NSViewGlobalFrameDidChangeNotification = @"NSViewFrameDidChangeNotification";

// NSTextField derives from the detached Cocoa view compatibility class.
// Its text editing uses UIKit's real text control and first responder.
@interface NSView : UIView
@end

@interface NSTextField : NSView
@property(nonatomic, copy) NSString *stringValue;
@property(nonatomic, getter=isEditable) BOOL editable;
@property(nonatomic, getter=isSelectable) BOOL selectable;
@property(nonatomic, strong) UITextField *textControl;
@end

@implementation NSTextField
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _textControl = [[UITextField alloc] initWithFrame:self.bounds];
    _textControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_textControl];
    _editable = YES;
    _selectable = YES;
    return self;
}
- (NSString *)stringValue { return self.textControl.text ?: @""; }
- (void)setStringValue:(NSString *)value { self.textControl.text = value; }
- (BOOL)canBecomeFirstResponder { return self.editable && self.textControl.canBecomeFirstResponder; }
- (BOOL)becomeFirstResponder { return self.editable && [self.textControl becomeFirstResponder]; }
- (BOOL)resignFirstResponder { return [self.textControl resignFirstResponder]; }
@end

@interface NSTextView : UITextView
@property(nonatomic, copy) NSString *string;
@end
@implementation NSTextView
- (NSString *)string { return self.text ?: @""; }
- (void)setString:(NSString *)string { self.text = string; }
@end

// Keep normal Cocoa controller content and selection. Any original license
// checks, nib loading, or user authorization remain owned by the plug-in.
@interface NSObjectController : NSObject
@property(nonatomic, strong) id content;
@property(nonatomic, readonly) id selection;
@property(nonatomic, readonly) NSArray *selectedObjects;
@end
@implementation NSObjectController
+ (NSSet<NSString *> *)keyPathsForValuesAffectingSelection { return [NSSet setWithObject:@"content"]; }
+ (NSSet<NSString *> *)keyPathsForValuesAffectingSelectedObjects { return [NSSet setWithObject:@"content"]; }
- (id)selection { return self.content ?: NSNull.null; }
- (NSArray *)selectedObjects { return self.content ? @[self.content] : @[]; }
@end

@interface NSAlert : NSObject
@property(nonatomic, copy) NSString *messageText;
@property(nonatomic, copy) NSString *informativeText;
@property(nonatomic) NSInteger alertStyle;
@property(nonatomic, strong) NSMutableArray<UIButton *> *buttons;
@end
@implementation NSAlert
- (UIButton *)addButtonWithTitle:(NSString *)title {
    if (!self.buttons) self.buttons = [NSMutableArray new];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [self.buttons addObject:button];
    return button;
}
- (NSInteger)runModal {
    // A background audio extension cannot present an app-modal dialog.
    // Return the AppKit abort response rather than implying consent.
    if (!NSThread.isMainThread) return -1001;
    UIViewController *presenter = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:UIWindowScene.class]) {
            presenter = ((UIWindowScene *)scene).keyWindow.rootViewController;
            if (presenter) break;
        }
    }
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter.view.window) return -1001;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.messageText
        message:self.informativeText preferredStyle:UIAlertControllerStyleAlert];
    if (!self.buttons.count) [self addButtonWithTitle:NSLocalizedString(@"OK", nil)];
    __block NSInteger response = -1001;
    [self.buttons enumerateObjectsUsingBlock:^(UIButton *button, NSUInteger index, BOOL *stop) {
        [alert addAction:[UIAlertAction actionWithTitle:button.currentTitle style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { response = 1000 + index; }]];
    }];
    [presenter presentViewController:alert animated:YES completion:nil];
    while (response == -1001 && alert.presentingViewController)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return response;
}
@end

@interface NSGraphicsContext : NSObject
@property(nonatomic, readonly) CGContextRef CGContext;
@end

@implementation NSGraphicsContext (BWFabFilterGraphicsPort)
- (CGContextRef)graphicsPort { return self.CGContext; }
@end
