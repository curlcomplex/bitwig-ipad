#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

static char metalLayerKey;
extern void BWPrepareNAMMetalLayer(CAMetalLayer *layer);

static CALayer *backingLayer(id view) {
    IMP getter = class_getMethodImplementation(UIView.class, @selector(layer));
    return ((CALayer *(*)(id, SEL))getter)(view, @selector(layer));
}

static CALayer *pluginLayer(id view, SEL selector) {
    return objc_getAssociatedObject(view, &metalLayerKey) ?: backingLayer(view);
}

static void setPluginLayer(id view, SEL selector, CAMetalLayer *layer) {
    [objc_getAssociatedObject(view, &metalLayerKey) removeFromSuperlayer];
    objc_setAssociatedObject(view, &metalLayerKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CALayer *backing = backingLayer(view);
    BWPrepareNAMMetalLayer(layer);
    layer.frame = backing.bounds;
    layer.contentsScale = ((UIView *)view).contentScaleFactor;
    layer.drawableSize = CGSizeMake(layer.bounds.size.width * layer.contentsScale,
                                    layer.bounds.size.height * layer.contentsScale);
    if (layer) [backing addSublayer:layer];
}

@interface BWNAMToolTip : UIToolTipInteraction <UIToolTipInteractionDelegate>
@property(nonatomic, weak) id owner;
@property(nonatomic) CGRect area;
@property(nonatomic) void *userData;
@end

@implementation BWNAMToolTip
- (UIToolTipConfiguration *)toolTipInteraction:(UIToolTipInteraction *)interaction
                        configurationAtPoint:(CGPoint)point {
    if (!CGRectContainsPoint(self.area, point)) return nil;
    SEL selector = @selector(view:stringForToolTip:point:userData:);
    id owner = self.owner;
    if (![owner respondsToSelector:selector]) return nil;
    NSInteger tag = (NSInteger)(__bridge void *)self;
    NSString *text = ((id (*)(id, SEL, UIView *, NSInteger, CGPoint, void *))objc_msgSend)(
        owner, selector, self.view, tag, point, self.userData);
    return text.length ? [UIToolTipConfiguration configurationWithToolTip:text inRect:self.area] : nil;
}
@end

static NSInteger addToolTip(UIView *view, SEL selector, CGRect area, id owner, void *userData) {
    BWNAMToolTip *interaction = [BWNAMToolTip new];
    interaction.delegate = interaction;
    interaction.owner = owner;
    interaction.area = area;
    interaction.userData = userData;
    [view addInteraction:interaction];
    return (NSInteger)(__bridge void *)interaction;
}

static void removeAllToolTips(UIView *view, SEL selector) {
    for (id<UIInteraction> interaction in view.interactions)
        if ([interaction isKindOfClass:BWNAMToolTip.class]) [view removeInteraction:interaction];
}

BOOL BWIsNAMEditorView(UIView *view) {
    Class cls = object_getClass(view);
    return cls && !strcmp(class_getName(cls), "IGraphicsView_vNeuralAmpModeler_vst3");
}

void BWPrepareNAMView(UIView *view) {
    if (!BWIsNAMEditorView(view)) return;
    Class cls = object_getClass(view);
    class_addMethod(cls, @selector(layer), (IMP)pluginLayer, "@@:");
    class_addMethod(cls, @selector(setLayer:), (IMP)setPluginLayer, "v@:@");
    class_addMethod(cls, @selector(addToolTipRect:owner:userData:), (IMP)addToolTip,
                    "q@:{CGRect={CGPoint=dd}{CGSize=dd}}@^v");
    class_addMethod(cls, @selector(removeAllToolTips), (IMP)removeAllToolTips, "v@:");
}
