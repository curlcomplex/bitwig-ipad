#import <UIKit/UIKit.h>
#import "../LocalConfiguration.h"
#import "EditorSurface.h"
#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

extern BOOL BWDeliverDetachedEditorPointer(UIView *view, CGPoint point, CGPoint delta, NSInteger type);

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

@interface BWEditorPublisher : NSObject
@property(nonatomic, strong) BWEditorMapping *mapping;
@property(nonatomic, strong) UIView *parent;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) dispatch_block_t close;
@property(nonatomic) CGPoint lastPoint;
@property(nonatomic) BOOL pressed;
@property(nonatomic) CGContextRef bitmap;
@property(nonatomic, strong) UIGraphicsImageRenderer *renderer;
- (void)tick;
@end

@implementation BWEditorPublisher
- (void)tick {
    UIView *editor = self.parent.subviews.firstObject;
    BWEditorMapping *mapping = self.mapping;
    if (!editor || ![mapping lock]) return;
    BWEditorSurface *surface = mapping.surface;
    BWEditorPointer pending[BWEditorPointerCapacity];
    uint8_t count = 0;
    uint8_t available = MIN(surface->pointerCount, BWEditorPointerCapacity);
    while (count < available) {
        BWEditorPointer event = surface->pointers[(surface->pointerRead + count) % BWEditorPointerCapacity];
        pending[count++] = event;
        // JUCE schedules button edges on its main run loop. Let that edge
        // settle before forwarding the next drag or button edge.
        if (event.phase != BWEditorPointerMove) break;
    }
    surface->pointerCount = available - count;
    surface->pointerRead = (surface->pointerRead + count) % BWEditorPointerCapacity;
    BOOL close = surface->closeRequested;
    surface->closeRequested = 0;
    [mapping unlock];

    for (uint8_t i = 0; i < count; ++i) {
        BWEditorPointer event = pending[i];
        if ((event.phase == BWEditorPointerDown) == self.pressed || !isfinite(event.x) || !isfinite(event.y)) continue;
        CGPoint point = CGPointMake(event.x, event.y);
        CGPoint delta = self.pressed ? CGPointMake(point.x - self.lastPoint.x, point.y - self.lastPoint.y) : CGPointZero;
        if (BWDeliverDetachedEditorPointer(editor, point, delta, event.phase)) {
            self.pressed = event.phase != BWEditorPointerUp;
            self.lastPoint = point;
        }
    }
    if (close) {
        if (self.pressed) BWDeliverDetachedEditorPointer(editor, self.lastPoint, CGPointZero, BWEditorPointerUp);
        self.pressed = NO;
        self.close();
        return;
    }

    if (!self.mapping) return;
    [editor layoutIfNeeded];
    CGSize size = editor.bounds.size;
    if (!isfinite(size.width) || !isfinite(size.height) || size.width < 1 || size.height < 1 ||
        size.width > UINT32_MAX || size.height > UINT32_MAX) return;
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
        CGContextScaleCTM(render.CGContext, width / size.width, height / size.height);
        [editor drawRect:editor.bounds];
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
        if (!self.mapping || ![mapping lock]) return;
        memcpy(surface->pixels, CGBitmapContextGetData(context), width * height * 4);
        surface->width = (uint32_t)width;
        surface->height = (uint32_t)height;
        surface->stride = (uint32_t)(width * 4);
        surface->pointsWide = (uint32_t)size.width;
        surface->pointsHigh = (uint32_t)size.height;
        surface->heartbeat = NSProcessInfo.processInfo.systemUptime;
        surface->visible = 1;
        ++surface->sequence;
        [mapping unlock];
    }
}
- (void)dealloc { if (_bitmap) CGContextRelease(_bitmap); }
@end

id BWPublishDetachedEditor(UIView *parent, dispatch_block_t close) {
    NSURL *directory = surfaceDirectory();
    if (!directory || ![NSFileManager.defaultManager createDirectoryAtURL:directory
                                                  withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    NSString *name = [NSString stringWithFormat:@"%d-%@", getpid(), NSUUID.UUID.UUIDString];
    NSURL *url = [directory URLByAppendingPathComponent:name];
    BWEditorMapping *mapping = [[BWEditorMapping alloc] initWithURL:url create:YES];
    if (!mapping) return nil;
    BWEditorPublisher *publisher = [BWEditorPublisher new];
    publisher.parent = parent;
    publisher.mapping = mapping;
    publisher.close = close;
    __weak BWEditorPublisher *weakPublisher = publisher;
    publisher.timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        BWEditorPublisher *current = weakPublisher;
        if (current) [current tick]; else [timer invalidate];
    }];
    [NSRunLoop.mainRunLoop addTimer:publisher.timer forMode:NSRunLoopCommonModes];
    return publisher;
}

void BWStopPublishingDetachedEditor(BWEditorPublisher *publisher) {
    if (publisher.pressed)
        BWDeliverDetachedEditorPointer(publisher.parent.subviews.firstObject, publisher.lastPoint, CGPointZero, BWEditorPointerUp);
    [publisher.timer invalidate];
    if ([publisher.mapping lock]) {
        publisher.mapping.surface->visible = 0;
        [publisher.mapping unlock];
    }
    publisher.mapping = nil;
}

@interface BWEditorViewport : UIView
@property(nonatomic, strong) BWEditorMapping *mapping;
@property(nonatomic, strong) UIImageView *image;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) NSMutableArray<NSValue *> *pending;
@property(nonatomic, strong) UITouch *contact;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) CGSize editorSize;
@property(nonatomic) BOOL closing;
- (BOOL)refresh;
@end

@implementation BWEditorViewport
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.9];
    self.pending = [NSMutableArray new];
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
- (void)send:(UITouch *)touch phase:(uint8_t)phase {
    if (self.closing || CGRectIsEmpty(self.image.bounds)) return;
    CGPoint position = [touch locationInView:self.image];
    BWEditorPointer event = {.x = position.x * self.editorSize.width / self.image.bounds.size.width,
                             .y = position.y * self.editorSize.height / self.image.bounds.size.height, .phase = phase};
    BWEditorPointer last = {0};
    [self.pending.lastObject getValue:&last size:sizeof(last)];
    if (phase == BWEditorPointerMove && last.phase == BWEditorPointerMove) [self.pending removeLastObject];
    if (phase == BWEditorPointerMove && self.pending.count >= BWEditorPointerCapacity - 1) return;
    [self.pending addObject:[NSValue valueWithBytes:&event objCType:@encode(BWEditorPointer)]];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (self.contact || self.pending.count >= BWEditorPointerCapacity - 1 ||
        !CGRectContainsPoint(self.image.frame, [touch locationInView:self])) return;
    self.contact = touch;
    [self send:touch phase:BWEditorPointerDown];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.contact && [touches containsObject:self.contact]) [self send:self.contact phase:BWEditorPointerMove];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.contact || ![touches containsObject:self.contact]) return;
    [self send:self.contact phase:BWEditorPointerUp];
    self.contact = nil;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
- (BOOL)refresh {
    if (![self.mapping lock]) return YES;
    BWEditorSurface *surface = self.mapping.surface;
    CGFloat age = NSProcessInfo.processInfo.systemUptime - surface->heartbeat;
    BOOL active = surface->version == BWEditorSurfaceVersion && surface->visible && age >= 0 && age < 2;
    if (!active) {
        [self.mapping unlock];
        return NO;
    }
    if (self.closing) surface->closeRequested = 1;
    uint8_t count = 0;
    while (surface->pointerCount < BWEditorPointerCapacity && count < self.pending.count) {
        NSUInteger index = (surface->pointerRead + surface->pointerCount++) % BWEditorPointerCapacity;
        [self.pending[count++] getValue:&surface->pointers[index] size:sizeof(BWEditorPointer)];
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

void BWPollDetachedEditors(UIWindowScene *scene) {
    static NSMutableDictionary<NSURL *, BWEditorViewport *> *viewports;
    if (!viewports) viewports = [NSMutableDictionary new];
    for (NSURL *url in viewports.allKeys) {
        BWEditorViewport *viewport = viewports[url];
        if ([viewport refresh]) continue;
        [viewport removeFromSuperview];
        [viewports removeObjectForKey:url];
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
            unlink(url.fileSystemRepresentation);
            continue;
        }
        if (!ready) continue;
        BWEditorViewport *viewport = [[BWEditorViewport alloc] initWithFrame:host.bounds];
        viewport.mapping = mapping;
        if (![viewport refresh]) continue;
        [host addSubview:viewport];
        viewports[url] = viewport;
    }
}
