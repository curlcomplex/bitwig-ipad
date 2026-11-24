// Built without ARC so the original Metal "new" ownership convention is
// preserved across the C IMP adapters. Only this host process is affected.
#import <Metal/Metal.h>
#import <objc/runtime.h>

static id (*newLength)(id,SEL,NSUInteger,MTLResourceOptions);
static id (*newBytes)(id,SEL,const void*,NSUInteger,MTLResourceOptions);
static id (*newNoCopy)(id,SEL,void*,NSUInteger,MTLResourceOptions,id);
static NSMutableDictionary *bufferModifyMethods;

static MTLResourceOptions iosOptions(MTLResourceOptions options) {
    // Managed == 1 is a desktop CPU/GPU synchronization policy. Shared memory
    // provides the corresponding coherent allocation on iOS/Apple Silicon.
    return ((options & MTLResourceStorageModeMask)>>MTLResourceStorageModeShift)==1
        ? options & ~MTLResourceStorageModeMask : options;
}
static void didModify(id buffer,SEL selector,NSRange range) {
    if([buffer storageMode]==MTLStorageModeShared)return; // Already coherent.
    NSValue *value;
    @synchronized(bufferModifyMethods){value=bufferModifyMethods[NSStringFromClass(object_getClass(buffer))];}
    void (*original)(id,SEL,NSRange)=[value pointerValue];
    if(original)original(buffer,selector,range);
    else [NSException raise:NSInvalidArgumentException format:@"didModifyRange requires CPU-visible shared storage"];
}
static id prepareBuffer(id buffer) {
    if(!buffer)return nil;
    Class cls=object_getClass(buffer);NSString *key=NSStringFromClass(cls);
    @synchronized(bufferModifyMethods) {
        if(!bufferModifyMethods[key]) {
            SEL selector=NSSelectorFromString(@"didModifyRange:");
            Method method=class_getInstanceMethod(cls,selector);
            bufferModifyMethods[key]=[NSValue valueWithPointer:method?method_getImplementation(method):NULL];
            class_replaceMethod(cls,selector,(IMP)didModify,method?method_getTypeEncoding(method):"v@:{_NSRange=QQ}");
        }
    }
    return buffer;
}
static id lengthBuffer(id device,SEL selector,NSUInteger length,MTLResourceOptions options) {
    return prepareBuffer(newLength(device,selector,length,iosOptions(options)));
}
static id bytesBuffer(id device,SEL selector,const void *bytes,NSUInteger length,MTLResourceOptions options) {
    return prepareBuffer(newBytes(device,selector,bytes,length,iosOptions(options)));
}
static id noCopyBuffer(id device,SEL selector,void *bytes,NSUInteger length,MTLResourceOptions options,id deallocator) {
    return prepareBuffer(newNoCopy(device,selector,bytes,length,iosOptions(options),deallocator));
}
static IMP replace(Class cls,SEL selector,IMP implementation) {
    Method method=class_getInstanceMethod(cls,selector);
    if(!method)[NSException raise:NSInvalidArgumentException format:@"Missing Metal method %@",NSStringFromSelector(selector)];
    IMP original=method_getImplementation(method);
    class_replaceMethod(cls,selector,implementation,method_getTypeEncoding(method));return original;
}
void BWUIKitPrepareMetal(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        bufferModifyMethods=[NSMutableDictionary new];
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        Class cls=object_getClass(device);
        newLength=(void*)replace(cls,@selector(newBufferWithLength:options:),(IMP)lengthBuffer);
        newBytes=(void*)replace(cls,@selector(newBufferWithBytes:length:options:),(IMP)bytesBuffer);
        newNoCopy=(void*)replace(cls,@selector(newBufferWithBytesNoCopy:length:options:deallocator:),(IMP)noCopyBuffer);
        [device release];
    });
}
