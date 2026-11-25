#import <UIKit/UIKit.h>
#if BW_JUCE_EDITOR
#import <objc/runtime.h>
#endif
#import "../LocalConfiguration.h"
#import "../HardwareKeys.h"
#import "EditorSurface.h"
#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

extern BOOL BWDeliverDetachedEditorPointer(UIView *view, CGPoint point, CGPoint delta, NSInteger type);
extern BOOL BWDeliverDetachedEditorPointerWithModifiers(UIView *view, CGPoint point, CGPoint delta, NSInteger type, NSUInteger modifiers);
extern BOOL BWDeliverDetachedEditorKey(UIView *view, NSInteger type, unsigned short keyCode, NSUInteger modifiers,
                                      NSString *characters, NSString *unmodified, BOOL repeat);

#if BW_IPLUG_EDITOR
extern BOOL BWIsNAMEditorView(UIView *view);
extern NSData *BWNAMMetalFrame(UIView *editor, NSUInteger *width, NSUInteger *height, uint64_t *sequence);
#endif

static BOOL isMove(uint8_t phase) { return phase == BWEditorPointerMove || phase == BWEditorSecondaryMove; }

static NSURL *surfaceDirectory(void) {
    return [BWSharedContainerURL() URLByAppendingPathComponent:@"Plugin Editors" isDirectory:YES];
}

@interface BWEditorMapping : NSObject
@property(nonatomic) int descriptor;
@property(nonatomic) BWEditorSurface *surface;
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) BOOL ownsFile;
- (instancetype)initWithURL:(NSURL *)url create:(BOOL)create;
- (BOOL)lock;
- (void)unlock;
@end

@implementation BWEditorMapping
- (instancetype)initWithURL:(NSURL *)url create:(BOOL)create {
    if (!(self = [super init])) return nil;
    _descriptor = -1;
    if (!url) return nil;
    _url = url;
    int flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW;
    _descriptor = open(url.fileSystemRepresentation, create ? flags | O_CREAT | O_EXCL : flags, 0600);
    if (_descriptor < 0) return nil;
    _ownsFile = create;
    if (create && ftruncate(_descriptor, sizeof(BWEditorSurface))) return nil;
    struct stat stat;
    if (fstat(_descriptor, &stat) || !S_ISREG(stat.st_mode) || stat.st_size != sizeof(BWEditorSurface)) return nil;
    void *bytes = mmap(NULL, sizeof(BWEditorSurface), PROT_READ | PROT_WRITE, MAP_SHARED, _descriptor, 0);
    if (bytes == MAP_FAILED) return nil;
    _surface = bytes;
    if (create) {
        if (![self lock]) return nil;
        _surface->version = BWEditorSurfaceVersion;
        [self unlock];
    }
    return self;
}
- (BOOL)lock { return flock(self.descriptor, LOCK_EX | LOCK_NB) == 0; }
- (void)unlock { flock(self.descriptor, LOCK_UN); }
- (void)dealloc {
    if (_surface) munmap(_surface, sizeof(BWEditorSurface));
    if (_descriptor >= 0) close(_descriptor);
    if (_ownsFile) unlink(_url.fileSystemRepresentation);
}
@end

#if BW_IPLUG_EDITOR
extern id BWNAMPresentOpenPanel(NSString *extension, void (^complete)(NSURL *));
extern void BWNAMCancelOpenPanel(id panel);

static NSURL *documentURL(BWEditorMapping *mapping, NSString *suffix) {
    return [mapping.url URLByAppendingPathExtension:suffix];
}

static void removeDocumentExchange(BWEditorMapping *mapping) {
    if (!mapping) return;
    [NSFileManager.defaultManager removeItemAtURL:documentURL(mapping, @"nam-request") error:nil];
    [NSFileManager.defaultManager removeItemAtURL:documentURL(mapping, @"nam-result") error:nil];
}
#endif

#if BW_JUCE_EDITOR
@class BWEditorPublisher;
@interface BWJucePopup : NSObject
@property(nonatomic, weak) BWEditorPublisher *publisher;
@property(nonatomic, strong) UIView *view;
@property(nonatomic) CGRect frame;
@end
@implementation BWJucePopup
@end
#endif

@interface BWEditorPublisher : NSObject
@property(nonatomic, strong) BWEditorMapping *mapping;
@property(nonatomic, strong) UIView *parent;
@property(nonatomic, strong) UIView *view;
@property(nonatomic, weak) UIView *focusedJuceView;
#if BW_JUCE_EDITOR
@property(nonatomic, strong) NSMutableArray<BWJucePopup *> *jucePopups;
@property(nonatomic, weak) UIView *juceEditor;
@property(nonatomic, weak) UIView *pointerView;
@property(nonatomic) CGPoint pointerOrigin;
#endif
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) dispatch_block_t close;
@property(nonatomic) CGPoint lastPoint;
@property(nonatomic) uint8_t pointerRelease;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *heldKeys;
@property(nonatomic) CGContextRef bitmap;
@property(nonatomic, strong) UIGraphicsImageRenderer *renderer;
#if BW_IPLUG_EDITOR
@property(nonatomic, copy) void (^documentReply)(NSURL *);
@property(nonatomic) uint64_t metalFrameSequence;
#endif
- (void)tick;
- (void)releaseInput;
@end

#if BW_IPLUG_EDITOR
static NSMapTable<UIView *, BWEditorPublisher *> *namPublishers;
static __weak BWEditorPublisher *editorDispatch;

// NAM's folder controls invoke their actions when the original renderer
// finishes the click animation, after the input callback has returned.
void BWDispatchNAMRender(UIView *view, SEL selector, IMP original) {
    BWEditorPublisher *publisher = NSThread.isMainThread ? [namPublishers objectForKey:view] : nil;
    if (!publisher) {
        ((void (*)(id, SEL))original)(view, selector);
        return;
    }
    BWEditorPublisher *priorDispatch = editorDispatch;
    editorDispatch = publisher;
    @try { ((void (*)(id, SEL))original)(view, selector); }
    @finally { editorDispatch = priorDispatch; }
}

BOOL BWNAMRequestOpenPanel(NSString *extension, void (^complete)(NSURL *)) {
    BWEditorPublisher *publisher = editorDispatch;
    if (!publisher || !BWIsNAMEditorView(publisher.view) || publisher.documentReply ||
        !([extension isEqualToString:@"nam"] || [extension isEqualToString:@"wav"])) return NO;
    NSURL *request = documentURL(publisher.mapping, @"nam-request");
    if (![extension writeToURL:request atomically:YES encoding:NSUTF8StringEncoding error:nil]) return NO;
    publisher.documentReply = complete;
    return YES;
}
#endif

#if BW_JUCE_EDITOR
extern void BWSetDetachedJuceCursor(CGPoint point);
extern void BWClearDetachedJuceButton(BOOL secondary);
static NSMapTable<UIView *, BWEditorPublisher *> *jucePublishers;
static __weak BWEditorPublisher *juceInputPublisher;
static char juceMouseDownImplementationKey;

static BOOL isJuceView(UIView *view) {
    return [NSStringFromClass(view.class) hasPrefix:@"JUCEView_"];
}

static void dispatchJuceMouseDown(UIView *view, SEL selector, id event) {
    NSValue *stored = objc_getAssociatedObject(view.class, &juceMouseDownImplementationKey);
    IMP original = (IMP)stored.pointerValue;
    BWEditorPublisher *publisher = [jucePublishers objectForKey:view];
    BWEditorPublisher *prior = juceInputPublisher;
    juceInputPublisher = publisher.mapping ? publisher : nil;
    @try { ((void (*)(id, SEL, id))original)(view, selector, event); }
    @finally { juceInputPublisher = prior; }
}

static BOOL trackJuceView(UIView *view, BWEditorPublisher *publisher) {
    if (!isJuceView(view)) return NO;
    Class cls = view.class;
    if (!objc_getAssociatedObject(cls, &juceMouseDownImplementationKey)) {
        SEL selector = @selector(asyncMouseDown:);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) return NO;
        IMP original = method_getImplementation(method);
        objc_setAssociatedObject(cls, &juceMouseDownImplementationKey, [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!class_addMethod(cls, selector, (IMP)dispatchJuceMouseDown, method_getTypeEncoding(method)))
            method_setImplementation(method, (IMP)dispatchJuceMouseDown);
    }
    if (!jucePublishers) jucePublishers = [NSMapTable weakToWeakObjectsMapTable];
    [jucePublishers setObject:publisher forKey:view];
    return YES;
}

static CGRect constrainJucePopupFrame(BWEditorPublisher *publisher, CGRect frame) {
    // A detached menu has the editor surface as its visible desktop area.
    CGRect bounds = publisher.juceEditor.bounds;
    CGFloat maxX = MAX(CGRectGetMinX(bounds), CGRectGetMaxX(bounds) - CGRectGetWidth(frame));
    CGFloat maxY = MAX(CGRectGetMinY(bounds), CGRectGetMaxY(bounds) - CGRectGetHeight(frame));
    frame.origin.x = MIN(MAX(frame.origin.x, CGRectGetMinX(bounds)), maxX);
    frame.origin.y = MIN(MAX(frame.origin.y, CGRectGetMinY(bounds)), maxY);
    return frame;
}

id BWAttachJucePopup(UIView *view, CGRect *frame) {
    BWEditorPublisher *publisher = juceInputPublisher;
    if (!publisher.mapping || CGRectIsEmpty(*frame) || CGRectIsInfinite(*frame) ||
        !trackJuceView(view, publisher)) return nil;
    BWJucePopup *popup = [BWJucePopup new];
    popup.publisher = publisher;
    popup.view = view;
    *frame = constrainJucePopupFrame(publisher, *frame);
    popup.frame = *frame;
    [publisher.jucePopups addObject:popup];
    return popup;
}

CGRect BWUpdateJucePopupFrame(BWJucePopup *popup, CGRect frame) {
    if (!CGRectIsEmpty(frame) && !CGRectIsInfinite(frame))
        popup.frame = constrainJucePopupFrame(popup.publisher, frame);
    return popup.frame;
}

void BWDetachJucePopup(BWJucePopup *popup) {
    if (!popup) return;
    BWEditorPublisher *publisher = popup.publisher;
    if ([jucePublishers objectForKey:popup.view] == publisher) [jucePublishers removeObjectForKey:popup.view];
    [publisher.jucePopups removeObjectIdenticalTo:popup];
    if (publisher.pointerView == popup.view) {
        if (publisher.pointerRelease) BWClearDetachedJuceButton(publisher.pointerRelease == BWEditorSecondaryUp);
        publisher.pointerView = nil;
        publisher.pointerRelease = 0;
    }
    popup.publisher = nil;
}
#endif

@implementation BWEditorPublisher
- (BOOL)publishPixels:(const void *)pixels width:(NSUInteger)width height:(NSUInteger)height points:(CGSize)size {
    BWEditorMapping *mapping = self.mapping;
    if (![mapping lock]) return NO;
    BWEditorSurface *surface = mapping.surface;
    memcpy(surface->pixels, pixels, width * height * 4);
    surface->width = (uint32_t)width;
    surface->height = (uint32_t)height;
    surface->stride = (uint32_t)(width * 4);
    surface->pointsWide = (uint32_t)size.width;
    surface->pointsHigh = (uint32_t)size.height;
    surface->heartbeat = NSProcessInfo.processInfo.systemUptime;
    surface->visible = 1;
    ++surface->sequence;
    [mapping unlock];
    return YES;
}
- (void)tick {
    UIView *editor = self.view ?: self.parent.subviews.firstObject;
    BWEditorMapping *mapping = self.mapping;
    if (![mapping lock]) return;
    BWEditorSurface *surface = mapping.surface;
    BWEditorInput pending[BWEditorPointerCapacity];
    uint8_t count = 0;
    uint8_t available = MIN(surface->pointerCount, BWEditorPointerCapacity);
    while (count < available) {
        BWEditorInput *slot = &surface->pointers[(surface->pointerRead + count) % BWEditorPointerCapacity];
        BWEditorInput event = *slot;
        memset(slot, 0, sizeof(*slot));
        pending[count++] = event;
        // JUCE schedules button edges on its main run loop. Let that edge
        // settle before forwarding the next drag or button edge.
        if (!isMove(event.phase)) break;
    }
    surface->pointerCount = available - count;
    surface->pointerRead = (surface->pointerRead + count) % BWEditorPointerCapacity;
    BOOL close = surface->closeRequested;
    surface->closeRequested = 0;
    BOOL cancel = surface->cancelRequested;
    surface->cancelRequested = 0;
    [mapping unlock];

#if BW_IPLUG_EDITOR
    if (close) self.documentReply = nil;
    if (self.documentReply) {
        NSURL *result = documentURL(mapping, @"nam-result");
        NSString *path = [NSString stringWithContentsOfURL:result encoding:NSUTF8StringEncoding error:nil];
        if (path) {
            [NSFileManager.defaultManager removeItemAtURL:result error:nil];
            void (^complete)(NSURL *) = self.documentReply;
            self.documentReply = nil;
            NSURL *import = [[BWSharedContainerURL() URLByAppendingPathComponent:@"BitwigUser/Imports" isDirectory:YES] URLByResolvingSymlinksInPath];
            NSURL *file = path.length ? [[NSURL fileURLWithPath:path] URLByResolvingSymlinksInPath] : nil;
            NSString *root = [import.path stringByAppendingString:@"/"];
            complete(root && [file.path hasPrefix:root] ? file : nil);
            if (self.mapping != mapping) return;
        }
    }
#endif
    if (!close && count && !self.view && !self.focusedJuceView &&
        [NSStringFromClass(editor.class) hasPrefix:@"JUCEView_"]) {
        BOOL focused = [editor becomeFirstResponder];
        if (self.mapping != mapping) return;
        if (focused) self.focusedJuceView = editor;
    }
#if BW_IPLUG_EDITOR
    BWEditorPublisher *priorDispatch = editorDispatch;
    editorDispatch = self;
    @try {
#endif
        for (uint8_t i = 0; i < count; ++i) {
            BWEditorInput event = pending[i];
            if (event.phase >= BWEditorKeyDown && event.phase <= BWEditorKeyFlags) {
                if (event.textLength > BWEditorKeyTextCapacity || event.unmodifiedLength > BWEditorKeyTextCapacity) continue;
                NSString *text = [NSString stringWithCharacters:event.text length:event.textLength];
                NSString *plain = [NSString stringWithCharacters:event.unmodified length:event.unmodifiedLength];
                BOOL delivered = BWDeliverDetachedEditorKey(editor, event.phase, event.keyCode, event.modifiers, text, plain, event.repeat);
                if (self.mapping != mapping) return;
                if (delivered) {
                    if (event.held) self.heldKeys[@(event.keyCode)] = @(event.phase);
                    else [self.heldKeys removeObjectForKey:@(event.keyCode)];
                }
                continue;
            }
            BOOL begins = event.phase == BWEditorPointerDown || event.phase == BWEditorSecondaryDown;
            if (begins == (self.pointerRelease != 0) || !isfinite(event.x) || !isfinite(event.y)) continue;
            uint8_t expectedMove = self.pointerRelease == BWEditorSecondaryUp ? BWEditorSecondaryMove : BWEditorPointerMove;
            if (!begins && event.phase != self.pointerRelease && event.phase != expectedMove) continue;
            CGPoint point = CGPointMake(event.x, event.y);
            CGPoint delta = self.pointerRelease ? CGPointMake(point.x - self.lastPoint.x, point.y - self.lastPoint.y) : CGPointZero;
            UIView *pointerView = editor;
            CGPoint local = point;
#if BW_JUCE_EDITOR
            if (self.juceEditor) {
                BWSetDetachedJuceCursor(point);
                if (begins) {
                    self.pointerOrigin = CGPointZero;
                    for (BWJucePopup *popup in self.jucePopups.reverseObjectEnumerator) {
                        if (!CGRectContainsPoint(popup.frame, point)) continue;
                        pointerView = popup.view;
                        self.pointerOrigin = popup.frame.origin;
                        break;
                    }
                    if (pointerView == editor && self.jucePopups.count) {
                        // JUCE handles Escape in its modal menu. A click behind
                        // that menu must not also activate the underlying editor.
                        self.pointerRelease = event.phase + 1;
                        uint16_t escape = (uint16_t)BWMacVirtualKey(UIKeyboardHIDUsageKeyboardEscape);
                        BWDeliverDetachedEditorKey(editor, BWEditorKeyDown, escape, event.modifiers, @"\033", @"\033", NO);
                        if (self.mapping != mapping) return;
                        BWDeliverDetachedEditorKey(editor, BWEditorKeyUp, escape, event.modifiers, @"\033", @"\033", NO);
                        if (self.mapping != mapping) return;
                        continue;
                    }
                    self.pointerView = pointerView;
                } else {
                    pointerView = self.pointerView;
                    if (!pointerView) {
                        if (event.phase == self.pointerRelease) self.pointerRelease = 0;
                        continue;
                    }
                }
                local = CGPointMake(point.x - self.pointerOrigin.x, point.y - self.pointerOrigin.y);
            }
#endif
            BOOL delivered = BWDeliverDetachedEditorPointerWithModifiers(pointerView, local, delta, event.phase, event.modifiers);
            if (self.mapping != mapping) return;
            if (delivered) {
                if (begins) {
#if BW_JUCE_EDITOR
                    if (self.juceEditor && !self.pointerView) {
                        BWClearDetachedJuceButton(event.phase == BWEditorSecondaryDown);
                        continue;
                    }
#endif
                    self.pointerRelease = event.phase + 1;
                } else if (event.phase == self.pointerRelease) {
                    self.pointerRelease = 0;
#if BW_JUCE_EDITOR
                    self.pointerView = nil;
#endif
                }
                self.lastPoint = point;
            }
#if BW_JUCE_EDITOR
            else if (begins) self.pointerView = nil;
#endif
        }
#if BW_IPLUG_EDITOR
    } @finally { editorDispatch = priorDispatch; }
#endif
    if (cancel || close) {
        [self releaseInput];
        if (self.mapping != mapping) return;
    }
    if (close) {
        self.close();
        return;
    }

    if (!self.mapping || !editor) return;
    [editor layoutIfNeeded];
    CGSize size = editor.bounds.size;
    if (!isfinite(size.width) || !isfinite(size.height) || size.width < 1 || size.height < 1 ||
        size.width > UINT32_MAX || size.height > UINT32_MAX) return;
#if BW_IPLUG_EDITOR
    if (BWIsNAMEditorView(editor)) {
        NSUInteger width = 0, height = 0;
        uint64_t sequence = 0;
        NSData *pixels = BWNAMMetalFrame(editor, &width, &height, &sequence);
        if (pixels.length && sequence != self.metalFrameSequence) {
            if ([self publishPixels:pixels.bytes width:width height:height points:size])
                self.metalFrameSequence = sequence;
        } else if (self.metalFrameSequence && [mapping lock]) {
            // NanoVG draws only when dirty; a live editor may hold one frame.
            surface->heartbeat = NSProcessInfo.processInfo.systemUptime;
            [mapping unlock];
        }
        return;
    }
#endif
    CGFloat scale = MIN(1, MIN(BWEditorMaxWidth / size.width, BWEditorMaxHeight / size.height));
    size_t width = MAX(1, floor(size.width * scale)), height = MAX(1, floor(size.height * scale));
    CGSize raster = CGSizeMake(width, height);
    if (!CGSizeEqualToSize(self.renderer.format.bounds.size, raster)) {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1;
        format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
        self.renderer = [[UIGraphicsImageRenderer alloc] initWithSize:raster format:format];
    }
    UIImage *frame = [self.renderer imageWithActions:^(UIGraphicsImageRendererContext *render) {
        CGContextRef context = render.CGContext;
        CGContextScaleCTM(context, width / size.width, height / size.height);
        CGContextSaveGState(context);
        [editor drawRect:editor.bounds];
        CGContextRestoreGState(context);
#if BW_JUCE_EDITOR
        for (BWJucePopup *popup in self.jucePopups.copy) {
            CGRect frame = popup.frame;
            CGContextBeginTransparencyLayerWithRect(context, frame, NULL);
            CGContextSaveGState(context);
            CGContextClipToRect(context, frame);
            CGContextTranslateCTM(context, frame.origin.x, frame.origin.y);
            [popup.view drawRect:popup.view.bounds];
            CGContextRestoreGState(context);
            CGContextEndTransparencyLayer(context);
        }
#endif
    }];
    if (!self.bitmap || CGBitmapContextGetWidth(self.bitmap) != width || CGBitmapContextGetHeight(self.bitmap) != height) {
        if (self.bitmap) CGContextRelease(self.bitmap);
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        self.bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, color,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(color);
    }
    CGContextRef context = self.bitmap;
    if (context && frame.CGImage) {
        CGContextClearRect(context, CGRectMake(0, 0, width, height));
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), frame.CGImage);
        [self publishPixels:CGBitmapContextGetData(context) width:width height:height points:size];
    }
}
- (void)releaseInput {
    UIView *editor = self.view ?: self.parent.subviews.firstObject;
    BWEditorMapping *mapping = self.mapping;
    uint8_t pointerRelease = self.pointerRelease;
    NSDictionary<NSNumber *, NSNumber *> *heldKeys = self.heldKeys.copy;
    UIView *focused = self.focusedJuceView;
    UIView *pointerView = editor;
    CGPoint pointerPoint = self.lastPoint;
#if BW_JUCE_EDITOR
    if (self.juceEditor) {
        pointerView = self.pointerView;
        pointerPoint = CGPointMake(pointerPoint.x - self.pointerOrigin.x, pointerPoint.y - self.pointerOrigin.y);
        self.pointerView = nil;
    }
#endif
    self.pointerRelease = 0;
    [self.heldKeys removeAllObjects];
    self.focusedJuceView = nil;
    if (pointerRelease && pointerView) BWDeliverDetachedEditorPointer(pointerView, pointerPoint, CGPointZero, pointerRelease);
    for (NSNumber *key in heldKeys) {
        if (self.mapping != mapping) break;
        BWDeliverDetachedEditorKey(editor, heldKeys[key].integerValue == BWEditorKeyFlags ? BWEditorKeyFlags : BWEditorKeyUp,
                                  key.unsignedShortValue, 0, @"", @"", NO);
    }
    if (self.mapping == mapping) [focused resignFirstResponder];
}
- (void)dealloc { if (_bitmap) CGContextRelease(_bitmap); }
@end

static id publishEditor(UIView *parent, UIView *view, dispatch_block_t close) {
    NSURL *directory = surfaceDirectory();
    if (!directory || ![NSFileManager.defaultManager createDirectoryAtURL:directory
                                                  withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    NSString *name = [NSString stringWithFormat:@"%d-%@", getpid(), NSUUID.UUID.UUIDString];
    NSURL *url = [directory URLByAppendingPathComponent:name];
    BWEditorMapping *mapping = [[BWEditorMapping alloc] initWithURL:url create:YES];
    if (!mapping) return nil;
    BWEditorPublisher *publisher = [BWEditorPublisher new];
    publisher.parent = parent;
    publisher.view = view;
    publisher.mapping = mapping;
#if BW_JUCE_EDITOR
    if (trackJuceView(parent.subviews.firstObject, publisher)) {
        publisher.juceEditor = parent.subviews.firstObject;
        publisher.jucePopups = [NSMutableArray new];
    }
#endif
#if BW_IPLUG_EDITOR
    if (BWIsNAMEditorView(view)) {
        if (!namPublishers) namPublishers = [NSMapTable weakToWeakObjectsMapTable];
        [namPublishers setObject:publisher forKey:view];
    }
#endif
    publisher.close = close;
    publisher.heldKeys = [NSMutableDictionary new];
    __weak BWEditorPublisher *weakPublisher = publisher;
    publisher.timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        BWEditorPublisher *current = weakPublisher;
        if (current) [current tick]; else [timer invalidate];
    }];
    [NSRunLoop.mainRunLoop addTimer:publisher.timer forMode:NSRunLoopCommonModes];
    return publisher;
}

id BWPublishDetachedEditor(UIView *parent, dispatch_block_t close) {
    return publishEditor(parent, nil, close);
}

id BWPublishDetachedEditorView(UIView *view, dispatch_block_t close) {
    return publishEditor(nil, view, close);
}

void BWStopPublishingDetachedEditor(BWEditorPublisher *publisher) {
    BWEditorMapping *mapping = publisher.mapping;
    if (!mapping) return;
    [publisher.timer invalidate];
    publisher.mapping = nil;
    if ([mapping lock]) {
        mapping.surface->visible = 0;
        memset(mapping.surface->pointers, 0, sizeof(mapping.surface->pointers));
        mapping.surface->pointerCount = 0;
        [mapping unlock];
    }
#if BW_IPLUG_EDITOR
    publisher.documentReply = nil;
    if (publisher.view && [namPublishers objectForKey:publisher.view] == publisher)
        [namPublishers removeObjectForKey:publisher.view];
    removeDocumentExchange(mapping);
#endif
    [publisher releaseInput];
#if BW_JUCE_EDITOR
    for (BWJucePopup *popup in publisher.jucePopups.copy) BWDetachJucePopup(popup);
    if (publisher.juceEditor && [jucePublishers objectForKey:publisher.juceEditor] == publisher)
        [jucePublishers removeObjectForKey:publisher.juceEditor];
#endif
}

@interface BWEditorViewport : UIView
@property(nonatomic, strong) BWEditorMapping *mapping;
@property(nonatomic, strong) UIImageView *image;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) NSMutableArray<NSValue *> *pending;
@property(nonatomic, strong) UITouch *contact;
@property(nonatomic) BOOL secondary;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *heldKeys;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) CGSize editorSize;
@property(nonatomic) BOOL closing;
@property(nonatomic, weak) UIResponder *priorResponder;
#if BW_IPLUG_EDITOR
@property(nonatomic, strong) id documentPicker;
- (void)pollDocument;
- (void)cancelDocument;
#endif
- (BOOL)refresh;
@end

@implementation BWEditorViewport
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.9];
    self.pending = [NSMutableArray new];
    self.heldKeys = [NSMutableDictionary new];
    self.image = [UIImageView new];
    [self addSubview:self.image];
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"Close Plug-in" forState:UIControlStateNormal];
    [self.closeButton addTarget:self action:@selector(requestClose) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.closeButton];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    self.closeButton.frame = CGRectMake(CGRectGetMaxX(area) - 132, CGRectGetMinY(area), 128, 40);
    CGRect available = CGRectInset(area, 12, 12);
    available.origin.y += 36;
    available.size.height -= 36;
    CGFloat scale = MIN(available.size.width / MAX(1, self.editorSize.width),
                        available.size.height / MAX(1, self.editorSize.height));
    CGSize display = CGSizeMake(self.editorSize.width * scale, self.editorSize.height * scale);
    self.image.frame = CGRectMake(CGRectGetMidX(available) - display.width / 2,
                                  CGRectGetMidY(available) - display.height / 2, display.width, display.height);
}
- (void)requestClose { self.closing = YES; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (NSUInteger)pendingWithReleases { return self.pending.count + self.heldKeys.count + (self.contact != nil); }
- (void)enqueue:(BWEditorInput)input {
    [self.pending addObject:[NSValue valueWithBytes:&input objCType:@encode(BWEditorInput)]];
}
- (void)send:(UITouch *)touch phase:(uint8_t)phase modifiers:(NSUInteger)modifiers {
    if (self.closing || CGRectIsEmpty(self.image.bounds)) return;
    CGPoint position = [touch locationInView:self.image];
    BWEditorInput event = {.x = position.x * self.editorSize.width / self.image.bounds.size.width,
                           .y = position.y * self.editorSize.height / self.image.bounds.size.height,
                           .phase = phase, .modifiers = (uint32_t)modifiers};
    BWEditorInput last = {0};
    [self.pending.lastObject getValue:&last size:sizeof(last)];
    if (isMove(phase) && last.phase == phase) [self.pending removeLastObject];
    if (isMove(phase) && self.pendingWithReleases >= BWEditorPointerCapacity) return;
    [self enqueue:event];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (self.contact || self.pendingWithReleases > BWEditorPointerCapacity - 2 ||
        !CGRectContainsPoint(self.image.frame, [touch locationInView:self])) return;
    self.contact = touch;
    self.secondary = touch.type == UITouchTypeIndirectPointer &&
        (event.buttonMask & UIEventButtonMaskSecondary) && !(event.buttonMask & UIEventButtonMaskPrimary);
    [self send:touch phase:self.secondary ? BWEditorSecondaryDown : BWEditorPointerDown modifiers:event.modifierFlags];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.contact && [touches containsObject:self.contact])
        [self send:self.contact phase:self.secondary ? BWEditorSecondaryMove : BWEditorPointerMove modifiers:event.modifierFlags];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.contact || ![touches containsObject:self.contact]) return;
    [self send:self.contact phase:self.secondary ? BWEditorSecondaryUp : BWEditorPointerUp modifiers:event.modifierFlags];
    self.contact = nil;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
- (void)sendKeyboard:(NSSet<UIPress *> *)presses down:(BOOL)down {
    if (self.closing) return;
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) continue;
        NSInteger keyCode = BWMacVirtualKey(key.keyCode);
        if (keyCode < 0) continue;
        NSNumber *identity = @(key.keyCode);
        NSValue *held = self.heldKeys[identity];
        BOOL caps = key.keyCode == UIKeyboardHIDUsageKeyboardCapsLock;
        if (!down && !held && !caps) continue;
        NSUInteger reserve = down && !held && !caps ? 2 : (down || caps ? 1 : 0);
        if (self.pendingWithReleases + reserve > BWEditorPointerCapacity) continue;

        NSUInteger modifier = BWKeyModifier(key.keyCode);
        BOOL flagsChanged = modifier || caps;
        NSUInteger flags = key.modifierFlags;
        if (modifier) {
            flags &= ~modifier;
            if (down) flags |= modifier;
            for (NSNumber *other in self.heldKeys)
                if (![other isEqual:identity]) flags |= BWKeyModifier(other.integerValue);
        }
        BWEditorInput input = {.phase = flagsChanged ? BWEditorKeyFlags : (down ? BWEditorKeyDown : BWEditorKeyUp),
            .keyCode = (uint16_t)keyCode, .modifiers = (uint32_t)flags, .repeat = down && held && !flagsChanged,
            .held = down && !caps};
        NSString *text = flagsChanged ? @"" : key.characters;
        NSString *plain = flagsChanged ? @"" : key.charactersIgnoringModifiers;
        if (key.keyCode == UIKeyboardHIDUsageKeyboardDeleteOrBackspace) text = plain = @"\177";
        if (text.length <= BWEditorKeyTextCapacity) {
            input.textLength = (uint8_t)text.length;
            [text getCharacters:input.text range:NSMakeRange(0, text.length)];
        }
        if (plain.length <= BWEditorKeyTextCapacity) {
            input.unmodifiedLength = (uint8_t)plain.length;
            [plain getCharacters:input.unmodified range:NSMakeRange(0, plain.length)];
        }
        [self enqueue:input];
        if (input.held) self.heldKeys[identity] = self.pending.lastObject;
        else [self.heldKeys removeObjectForKey:identity];
    }
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self sendKeyboard:presses down:YES];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self sendKeyboard:presses down:NO];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self sendKeyboard:presses down:NO];
}
- (BOOL)resignFirstResponder {
    BOOL resigned = [super resignFirstResponder];
    if (!resigned || self.closing) return resigned;
    for (NSValue *value in self.heldKeys.allValues) {
        BWEditorInput input;
        [value getValue:&input size:sizeof(input)];
        if (input.phase == BWEditorKeyDown) input.phase = BWEditorKeyUp;
        input.held = 0;
        input.repeat = 0;
        input.modifiers &= UIKeyModifierAlphaShift;
        [self enqueue:input];
    }
    [self.heldKeys removeAllObjects];
    return YES;
}
#if BW_IPLUG_EDITOR
- (void)pollDocument {
    if (self.documentPicker || self.closing) return;
    NSURL *request = documentURL(self.mapping, @"nam-request");
    NSString *extension = [NSString stringWithContentsOfURL:request encoding:NSUTF8StringEncoding error:nil];
    if (!extension) return;
    [NSFileManager.defaultManager removeItemAtURL:request error:nil];
    NSURL *result = documentURL(self.mapping, @"nam-result");
    __weak BWEditorViewport *weakSelf = self;
    self.documentPicker = BWNAMPresentOpenPanel(extension, ^(NSURL *file) {
        BWEditorViewport *viewport = weakSelf;
        if (!viewport || viewport.closing) return;
        [(file.path ?: @"") writeToURL:result atomically:YES encoding:NSUTF8StringEncoding error:nil];
        viewport.documentPicker = nil;
    });
}
- (void)cancelDocument {
    if (self.documentPicker) BWNAMCancelOpenPanel(self.documentPicker);
    self.documentPicker = nil;
}
#endif
- (BOOL)refresh {
    if (![self.mapping lock]) return YES;
    BWEditorSurface *surface = self.mapping.surface;
    CGFloat age = NSProcessInfo.processInfo.systemUptime - surface->heartbeat;
    BOOL active = surface->version == BWEditorSurfaceVersion && surface->visible && age >= 0 && age < 2;
    if (!active) {
        if (surface->version == BWEditorSurfaceVersion && surface->visible) {
            memset(surface->pointers, 0, sizeof(surface->pointers));
            surface->pointerCount = 0;
            surface->cancelRequested = 1;
        }
        [self.mapping unlock];
        return NO;
    }
    if (self.closing) surface->closeRequested = 1;
    uint8_t count = 0;
    while (surface->pointerCount < BWEditorPointerCapacity && count < self.pending.count) {
        NSUInteger index = (surface->pointerRead + surface->pointerCount++) % BWEditorPointerCapacity;
        [self.pending[count++] getValue:&surface->pointers[index] size:sizeof(BWEditorInput)];
    }
    if (count) [self.pending removeObjectsInRange:NSMakeRange(0, count)];
    if (self.sequence == surface->sequence || !surface->width || surface->width > BWEditorMaxWidth ||
        !surface->height || surface->height > BWEditorMaxHeight || surface->stride != surface->width * 4) {
        [self.mapping unlock];
        return YES;
    }
    NSData *pixels = [NSData dataWithBytes:surface->pixels length:surface->stride * surface->height];
    size_t width = surface->width, height = surface->height;
    self.sequence = surface->sequence;
    CGSize editorSize = CGSizeMake(surface->pointsWide, surface->pointsHigh);
    [self.mapping unlock];

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGImageRef frame = CGImageCreate(width, height, 8, 32, width * 4, color,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, NULL, false, kCGRenderingIntentDefault);
    if (frame) {
        self.image.image = [UIImage imageWithCGImage:frame];
        CGImageRelease(frame);
    }
    CGColorSpaceRelease(color);
    CGDataProviderRelease(provider);
    if (!CGSizeEqualToSize(self.editorSize, editorSize)) {
        self.editorSize = editorSize;
        [self setNeedsLayout];
    }
    return YES;
}
@end

@implementation UIResponder (BWEditorFocus)
- (void)bwRememberEditorResponder:(BWEditorViewport *)viewport {
    if (self.isFirstResponder) viewport.priorResponder = self;
}
@end

static BOOL responderInWindow(UIResponder *responder, UIWindow *window) {
    while (responder) {
        if ([responder isKindOfClass:UIView.class]) return ((UIView *)responder).window == window;
        responder = responder.nextResponder;
    }
    return NO;
}

void BWPollDetachedEditors(UIWindowScene *scene) {
    static NSMutableDictionary<NSURL *, BWEditorViewport *> *viewports;
    if (!viewports) viewports = [NSMutableDictionary new];
    for (NSURL *url in viewports.allKeys) {
        BWEditorViewport *viewport = viewports[url];
        if ([viewport refresh]) {
#if BW_IPLUG_EDITOR
            [viewport pollDocument];
#endif
            continue;
        }
#if BW_IPLUG_EDITOR
        [viewport cancelDocument];
#endif
        UIWindow *window = viewport.window;
        BOOL focused = viewport.isFirstResponder;
        UIResponder *prior = viewport.priorResponder;
        [viewport removeFromSuperview];
        [viewports removeObjectForKey:url];
        if (focused && window.isKeyWindow && window.windowScene.activationState == UISceneActivationStateForegroundActive &&
            responderInWindow(prior, window)) [prior becomeFirstResponder];
    }
    UIView *host = scene.keyWindow.rootViewController.view;
    NSURL *directory = surfaceDirectory();
    if (!host || !directory) return;
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
                                          includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if (viewports[url]) continue;
        NSScanner *name = [NSScanner scannerWithString:url.lastPathComponent];
        int pid = 0;
        if (![name scanInt:&pid] || pid <= 1 || ![name scanString:@"-" intoString:nil] ||
            ![[NSUUID alloc] initWithUUIDString:[url.lastPathComponent substringFromIndex:name.scanLocation]]) continue;
        BWEditorMapping *mapping = [[BWEditorMapping alloc] initWithURL:url create:NO];
        if (!mapping || ![mapping lock]) continue;
        BOOL valid = mapping.surface->version == BWEditorSurfaceVersion;
        BOOL ready = valid && mapping.surface->sequence && mapping.surface->visible;
        double age = NSProcessInfo.processInfo.systemUptime - mapping.surface->heartbeat;
        [mapping unlock];
        if (valid && age > 30 && kill(pid, 0) == -1 && errno == ESRCH) {
#if BW_IPLUG_EDITOR
            removeDocumentExchange(mapping);
#endif
            unlink(url.fileSystemRepresentation);
            continue;
        }
        if (!ready) continue;
        BWEditorViewport *viewport = [[BWEditorViewport alloc] initWithFrame:host.bounds];
        viewport.mapping = mapping;
        if (![viewport refresh]) continue;
        [host addSubview:viewport];
        [UIApplication.sharedApplication sendAction:@selector(bwRememberEditorResponder:) to:nil from:viewport forEvent:nil];
        [viewport becomeFirstResponder];
        viewports[url] = viewport;
    }
}
