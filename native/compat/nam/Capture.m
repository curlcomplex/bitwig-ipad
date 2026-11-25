#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>
#import "../surge/EditorSurface.h"

@interface BWNAMCapture : NSObject
@property(nonatomic) BOOL pending;
@property(nonatomic) CFTimeInterval lastRequest;
@property(nonatomic) NSUInteger width;
@property(nonatomic) NSUInteger height;
@property(nonatomic) uint64_t sequence;
@property(nonatomic, strong) NSData *pixels;
@end
@implementation BWNAMCapture
@end

static char captureKey;

static void copyDrawable(id<MTLCommandBuffer> commands, id<CAMetalDrawable> drawable, BWNAMCapture *capture) {
    id<MTLTexture> texture = drawable.texture;
    NSUInteger width = texture.width, height = texture.height;
    if (texture.pixelFormat != MTLPixelFormatBGRA8Unorm || !width || !height ||
        width > BWEditorMaxWidth || height > BWEditorMaxHeight) return;

    CFTimeInterval now = CACurrentMediaTime();
    @synchronized (capture) {
        if (capture.pending || now - capture.lastRequest < 0.05) return;
        capture.pending = YES;
        capture.lastRequest = now;
    }
    NSUInteger stride = width * 4;
    NSUInteger alignedStride = (stride + 255) & ~(NSUInteger)255;
    id<MTLBuffer> buffer = [texture.device newBufferWithLength:alignedStride * height
                                                      options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = buffer ? [commands blitCommandEncoder] : nil;
    if (!blit) {
        @synchronized (capture) { capture.pending = NO; }
        return;
    }

    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1) toBuffer:buffer destinationOffset:0
   destinationBytesPerRow:alignedStride destinationBytesPerImage:alignedStride * height];
    [blit endEncoding];

    [commands addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        NSMutableData *pixels = nil;
        if (completed.status == MTLCommandBufferStatusCompleted) {
            pixels = [NSMutableData dataWithLength:stride * height];
            for (NSUInteger row = 0; row < height; ++row)
                memcpy((uint8_t *)pixels.mutableBytes + row * stride,
                       (const uint8_t *)buffer.contents + row * alignedStride, stride);
        }
        @synchronized (capture) {
            if (pixels) {
                capture.pixels = pixels;
                capture.width = width;
                capture.height = height;
                ++capture.sequence;
            }
            capture.pending = NO;
        }
    }];
}

typedef void (*PresentDrawable)(id<MTLCommandBuffer>, SEL, id<MTLDrawable>);

static void installPresentCapture(id<MTLDevice> device) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLCommandQueue> queue = [device newCommandQueue];
        Class cls = object_getClass([queue commandBuffer]);
        SEL selector = @selector(presentDrawable:);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) return;
        PresentDrawable present = (PresentDrawable)method_getImplementation(method);
        IMP capture = imp_implementationWithBlock(^(id<MTLCommandBuffer> commands, id<MTLDrawable> drawable) {
            BWNAMCapture *state = objc_getAssociatedObject(drawable, &captureKey);
            if (state) {
                objc_setAssociatedObject(drawable, &captureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                copyDrawable(commands, (id<CAMetalDrawable>)drawable, state);
            }
            present(commands, selector, drawable);
        });
        class_replaceMethod(cls, selector, capture, method_getTypeEncoding(method));
    });
}

typedef void (*SyncResource)(id, SEL, id<MTLResource>);
static SyncResource originalSyncResource;

static void syncResource(id encoder, SEL selector, id<MTLResource> resource) {
    Dl_info caller = {0};
    const void *address = __builtin_extract_return_addr(__builtin_return_address(0));
    if (dladdr(address, &caller) && caller.dli_fname) {
        const char *file = strrchr(caller.dli_fname, '/');
        if (file && !strcmp(file, "/NeuralAmpModeler.bundle")) {
            MTLStorageMode storage = resource.storageMode;
            if ((storage == MTLStorageModeShared || storage == MTLStorageModePrivate) &&
                [resource conformsToProtocol:@protocol(MTLTexture)]) {
                static dispatch_once_t logged;
                dispatch_once(&logged, ^{
                    NSLog(@"NAM offscreen texture uses iPad command ordering (storage mode %lu)", (unsigned long)storage);
                });
                return;
            }
        }
    }
    if (originalSyncResource) originalSyncResource(encoder, selector, resource);
    else [encoder doesNotRecognizeSelector:selector];
}

static void installNAMTextureSynchronization(id<MTLDevice> device) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        Class cls = object_getClass(blit);
        SEL selector = sel_registerName("synchronizeResource:");
        Method method = class_getInstanceMethod(cls, selector);
        if (cls) {
            if (method) originalSyncResource = (SyncResource)method_getImplementation(method);
            class_replaceMethod(cls, selector, (IMP)syncResource, method ? method_getTypeEncoding(method) : "v@:@");
        }
        [blit endEncoding];
    });
}

// This subclass adds no storage and is installed only on NAM's own layer.
@interface BWNAMMetalLayer : CAMetalLayer
@end
@implementation BWNAMMetalLayer
- (void)setDevice:(id<MTLDevice>)device {
    [super setDevice:device];
    if (device) installNAMTextureSynchronization(device);
}
- (id<CAMetalDrawable>)nextDrawable {
    if (self.device) installPresentCapture(self.device);
    id<CAMetalDrawable> drawable = [super nextDrawable];
    if (drawable) {
        BWNAMCapture *state = objc_getAssociatedObject(self, &captureKey);
        objc_setAssociatedObject(drawable, &captureKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return drawable;
}
- (void)setDrawableSize:(CGSize)size {
    // A detached AppKit view has no backing window scale. Its layer already
    // has the correct nonzero size from the plug-in or its view bounds.
    if ((size.width <= 0 || size.height <= 0) &&
        self.bounds.size.width > 0 && self.bounds.size.height > 0) {
        size = CGSizeMake(self.bounds.size.width * self.contentsScale,
                          self.bounds.size.height * self.contentsScale);
    }
    [super setDrawableSize:size];
}
@end

void BWPrepareNAMMetalLayer(CAMetalLayer *layer) {
    if (object_getClass(layer) != CAMetalLayer.class) return;
    objc_setAssociatedObject(layer, &captureKey, [BWNAMCapture new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    object_setClass(layer, BWNAMMetalLayer.class);
    layer.framebufferOnly = NO;
}

NSData *BWNAMMetalFrame(UIView *editor, NSUInteger *width, NSUInteger *height, uint64_t *sequence) {
    BWNAMCapture *state = objc_getAssociatedObject(editor.layer, &captureKey);
    if (!state) return nil;
    @synchronized (state) {
        *width = state.width;
        *height = state.height;
        *sequence = state.sequence;
        return state.pixels;
    }
}
