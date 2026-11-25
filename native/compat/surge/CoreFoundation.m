#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <unistd.h>

#if BW_SURGE_EDITOR
#include <clap/entry.h>
extern const clap_plugin_entry_t *BWEditorEntry(const clap_plugin_entry_t *entry);
#if BW_CHOW_EDITOR
extern const clap_plugin_entry_t *BWCHOWEditorEntry(const clap_plugin_entry_t *entry);
#endif
#endif

static CFArrayRef (*copyArchitectures)(CFBundleRef);
static Boolean (*systemLoad)(CFBundleRef,CFErrorRef *);
static void *(*systemFunction)(CFBundleRef,CFStringRef);
static NSLock *loaderLock;
static void *surgeImage;
static void *ottImage;
static void *namImage;
#if BW_CHOW_EDITOR
static void *chowImage;
#endif

static void resolveLoader(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaderLock=[NSLock new];
        void *system=dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",RTLD_LAZY|RTLD_LOCAL);
        if (!system) return;
        copyArchitectures=dlsym(system,"CFBundleCopyExecutableArchitectures");
        systemLoad=dlsym(system,"CFBundleLoadExecutableAndReturnError");
        systemFunction=dlsym(system,"CFBundleGetFunctionPointerForName");
    });
}
static NSString *embeddedPluginBinary(CFBundleRef bundle, void ***slot) {
    if (!bundle) return nil;
    NSURL *url=CFBridgingRelease(CFBundleCopyBundleURL(bundle));
    NSURL *app=NSBundle.mainBundle.bundleURL;
    if ([app.pathExtension isEqualToString:@"appex"])
        app=app.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSURL *frameworks=[app URLByAppendingPathComponent:@"Frameworks" isDirectory:YES];
    NSString *path=url.URLByStandardizingPath.path;
    if ([path isEqualToString:[frameworks URLByAppendingPathComponent:@"Surge XT.clap"].URLByStandardizingPath.path]) {
        if (slot) *slot=&surgeImage;
        return [frameworks URLByAppendingPathComponent:@"SurgeXT.bundle"].path;
    }
#if BW_CHOW_EDITOR
    if ([path isEqualToString:[frameworks URLByAppendingPathComponent:@"CHOWTapeModel.clap"].URLByStandardizingPath.path]) {
        if (slot) *slot=&chowImage;
        return [frameworks URLByAppendingPathComponent:@"CHOWTapeModel.bundle"].path;
    }
#endif
    if ([path isEqualToString:[frameworks URLByAppendingPathComponent:@"OTT.vst3"].URLByStandardizingPath.path]) {
        if (slot) *slot=&ottImage;
        return [frameworks URLByAppendingPathComponent:@"OTT.bundle"].path;
    }
    if ([path isEqualToString:[frameworks URLByAppendingPathComponent:@"NeuralAmpModeler.vst3"].URLByStandardizingPath.path]) {
        if (slot) *slot=&namImage;
        return [frameworks URLByAppendingPathComponent:@"NeuralAmpModeler.bundle"].path;
    }
    return nil;
}

// iPadOS can return no architectures for the desktop layout Bitwig indexes.
// Read the signed, embedded, thin image instead of guessing from the host CPU.
CFArrayRef CFBundleCopyExecutableArchitectures(CFBundleRef bundle) {
    resolveLoader();
    CFArrayRef architectures=copyArchitectures?copyArchitectures(bundle):NULL;
    if (architectures && CFArrayGetCount(architectures)>0) return architectures;
    NSString *path=embeddedPluginBinary(bundle,NULL);
    if (!path) return architectures;
    if (architectures) CFRelease(architectures);
    int image=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC);
    if (image<0) return NULL;
    struct mach_header_64 header;
    ssize_t readBytes=read(image,&header,sizeof(header));
    close(image);
    if (readBytes!=sizeof(header) || header.magic!=MH_MAGIC_64 ||
        header.cputype!=CPU_TYPE_ARM64 || header.filetype!=MH_BUNDLE) return NULL;
    int32_t architecture=header.cputype;
    CFNumberRef value=CFNumberCreate(NULL,kCFNumberSInt32Type,&architecture);
    if (!value) return NULL;
    const void *values[]={value};
    architectures=CFArrayCreate(NULL,values,1,&kCFTypeArrayCallBacks);
    CFRelease(value);
    fprintf(stderr,"Plug-in scanner read ARM64 architecture from %s\n",path.lastPathComponent.UTF8String);
    return architectures;
}


Boolean CFBundleLoadExecutableAndReturnError(CFBundleRef bundle, CFErrorRef *error) {
    resolveLoader();
    void **slot=NULL;
    NSString *path=embeddedPluginBinary(bundle,&slot);
    if (!path) return systemLoad?systemLoad(bundle,error):false;
    // Use CFBundle normally where supported. Hold the dlopen fallback for the
    // lifetime of this process so native factory pointers remain valid.
    CFErrorRef originalError=NULL;
    if (systemLoad&&systemLoad(bundle,&originalError)) {
        if (originalError) CFRelease(originalError);
        return true;
    }
    [loaderLock lock];
    if (!*slot) *slot=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    BOOL loaded=*slot!=NULL;
    if (!loaded) {
        const char *detail=dlerror();
        fprintf(stderr,"Embedded plug-in %s load failed: %s\n",path.lastPathComponent.UTF8String,detail?detail:"unknown loader error");
    }
    [loaderLock unlock];
    if (loaded || !error) {
        if (originalError) CFRelease(originalError);
    } else {
        *error=originalError;
    }
    return loaded;
}

void *CFBundleGetFunctionPointerForName(CFBundleRef bundle, CFStringRef name) {
    resolveLoader();
    void **slot=NULL;
    if (!embeddedPluginBinary(bundle,&slot)) return systemFunction?systemFunction(bundle,name):NULL;
    [loaderLock lock];
    void *function=*slot?dlsym(*slot,[(__bridge NSString *)name UTF8String]):NULL;
    [loaderLock unlock];
    if (!function && systemFunction) function=systemFunction(bundle,name);
#if BW_SURGE_EDITOR
    if (function && slot!=&ottImage && slot!=&namImage && CFEqual(name, CFSTR("clap_entry"))) {
        [loaderLock lock];
#if BW_CHOW_EDITOR
        if (slot==&chowImage) function=(void *)BWCHOWEditorEntry(function);
        else
#endif
            function=(void *)BWEditorEntry(function);
        [loaderLock unlock];
    }
#endif
    return function;
}
