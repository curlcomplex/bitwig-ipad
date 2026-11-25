#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <unistd.h>

#if BW_SURGE_EDITOR
#include <clap/entry.h>
extern const clap_plugin_entry_t *BWEditorEntry(const clap_plugin_entry_t *entry);
#endif

static CFArrayRef (*copyArchitectures)(CFBundleRef);
static Boolean (*systemLoad)(CFBundleRef,CFErrorRef *);
static void *(*systemFunction)(CFBundleRef,CFStringRef);
static NSLock *loaderLock;
static void *surgeImage;

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
static NSString *embeddedSurgeBinary(CFBundleRef bundle) {
    if (!bundle) return nil;
    NSURL *url=CFBridgingRelease(CFBundleCopyBundleURL(bundle));
    NSURL *app=NSBundle.mainBundle.bundleURL;
    if ([app.pathExtension isEqualToString:@"appex"])
        app=app.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSURL *expected=[app URLByAppendingPathComponent:@"Frameworks/Surge XT.clap" isDirectory:YES];
    if (![url.URLByStandardizingPath.path isEqualToString:expected.URLByStandardizingPath.path]) return nil;
    return [[expected.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"SurgeXT.bundle"] path];
}

// iPadOS can return no architectures for the desktop layout Bitwig indexes.
// Read the signed, embedded, thin image instead of guessing from the host CPU.
CFArrayRef CFBundleCopyExecutableArchitectures(CFBundleRef bundle) {
    resolveLoader();
    CFArrayRef architectures=copyArchitectures?copyArchitectures(bundle):NULL;
    if (architectures && CFArrayGetCount(architectures)>0) return architectures;
    NSString *path=embeddedSurgeBinary(bundle);
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
    fprintf(stderr,"Surge scanner read ARM64 architecture from signed bundle image\n");
    return architectures;
}


Boolean CFBundleLoadExecutableAndReturnError(CFBundleRef bundle, CFErrorRef *error) {
    resolveLoader();
    NSString *path=embeddedSurgeBinary(bundle);
    if (!path) return systemLoad?systemLoad(bundle,error):false;
    // Use CFBundle normally where supported. Hold the dlopen fallback for the
    // lifetime of this process, matching these callers' no-unload CLAP path.
    CFErrorRef originalError=NULL;
    if (systemLoad&&systemLoad(bundle,&originalError)) {
        if (originalError) CFRelease(originalError);
        return true;
    }
    [loaderLock lock];
    if (!surgeImage) surgeImage=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    BOOL loaded=surgeImage!=NULL;
    if (!loaded) {
        const char *detail=dlerror();
        fprintf(stderr,"Surge embedded binary load failed: %s\n",detail?detail:"unknown loader error");
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
    if (!embeddedSurgeBinary(bundle)) return systemFunction?systemFunction(bundle,name):NULL;
    [loaderLock lock];
    void *function=surgeImage?dlsym(surgeImage,[(__bridge NSString *)name UTF8String]):NULL;
    [loaderLock unlock];
    if (!function && systemFunction) function=systemFunction(bundle,name);
#if BW_SURGE_EDITOR
    if (function && CFEqual(name, CFSTR("clap_entry"))) {
        [loaderLock lock];
        function=(void *)BWEditorEntry(function);
        [loaderLock unlock];
    }
#endif
    return function;
}
