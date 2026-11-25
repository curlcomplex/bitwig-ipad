#import <UIKit/UIKit.h>

NSString *const NSPasteboardTypeFileURL = @"public.file-url";

@interface NSGraphicsContext : NSObject
@property(nonatomic) CGContextRef CGContext;
@property(nonatomic, getter=isFlipped) BOOL flipped;
@end

@implementation NSGraphicsContext
+ (instancetype)currentContext {
    CGContextRef context = UIGraphicsGetCurrentContext();
    return context ? [self graphicsContextWithCGContext:context flipped:YES] : nil;
}
+ (instancetype)graphicsContextWithCGContext:(CGContextRef)context flipped:(BOOL)flipped {
    NSGraphicsContext *wrapper = [self new];
    wrapper.CGContext = context;
    wrapper.flipped = flipped;
    return wrapper;
}
- (void)setCGContext:(CGContextRef)context {
    if (_CGContext == context) return;
    if (context) CGContextRetain(context);
    if (_CGContext) CGContextRelease(_CGContext);
    _CGContext = context;
}
- (void)dealloc { if (_CGContext) CGContextRelease(_CGContext); }
+ (void)saveGraphicsState {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context) CGContextSaveGState(context);
}
+ (void)restoreGraphicsState {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context) CGContextRestoreGState(context);
}
@end

@interface NSAccessibilityElement : UIAccessibilityElement
@property(nonatomic, weak) id accessibilityParent;
@end

@implementation NSAccessibilityElement
- (instancetype)init {
    // JUCE assigns the accessibility parent after initialization. UIKit
    // requires a non-nil container immediately, even for a detached view.
    static NSObject *detachedContainer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ detachedContainer = [NSObject new]; });
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIView *container = ((UIWindowScene *)scene).keyWindow.rootViewController.view;
        if (container) return [super initWithAccessibilityContainer:container];
    }
    return [super initWithAccessibilityContainer:detachedContainer];
}
- (id)accessibilityContainer { return self.accessibilityParent ?: [super accessibilityContainer]; }
@end

void NSAccessibilityPostNotificationWithUserInfo(id element, NSString *notification, NSDictionary *info) {
    if ([notification isEqualToString:@"AXAnnouncementRequested"]) {
        NSString *announcement = info[@"AXAnnouncementKey"];
        if (announcement.length) UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, announcement);
    } else if ([notification isEqualToString:@"AXFocusedUIElementChanged"] ||
               [notification isEqualToString:@"AXLayoutChanged"] ||
               [notification isEqualToString:@"AXCreated"]) {
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, element);
    }
}
