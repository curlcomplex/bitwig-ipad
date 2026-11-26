#import "../PluginPackage.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/file.h>
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
static void *fabFilterImages[22];
static NSDictionary<NSString *, NSDictionary *> *fabFilterManifest(NSURL *frameworks) {
    static NSDictionary<NSString *, NSDictionary *> *manifest;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfURL:[frameworks URLByAppendingPathComponent:@"fabfilter-clap.json"]];
        id contents = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([contents isKindOfClass:NSDictionary.class]) manifest = contents;
    });
    return manifest;
}

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
static NSMutableDictionary<NSString *, NSValue *> *preparedSlots;
static NSMutableDictionary<NSString *, NSString *> *preparedPaths;
static CFBundleRef preparedOTTBundle, preparedNAMBundle;
static bool (*preparedOTTEntry)(CFBundleRef);
static bool (*preparedNAMEntry)(CFBundleRef);

static bool enterPreparedOTT(CFBundleRef original) { return preparedOTTEntry(preparedOTTBundle); }
static bool enterPreparedNAM(CFBundleRef original) { return preparedNAMEntry(preparedNAMBundle); }

static NSString *preparedPluginBinary(NSURL *bundle,void ***slot) {
    NSString *name=bundle.lastPathComponent;
    NSURL *generation=BWPreparedPluginDirectory(bundle);
    if (!generation) return nil;
    NSString *image=BWPreparedPluginImageName(name);
    [loaderLock lock];
    if (!preparedPaths) { preparedPaths=[NSMutableDictionary new]; preparedSlots=[NSMutableDictionary new]; }
    NSString *path=preparedPaths[name];
    if (!path) {
        NSURL *imageURL=[generation URLByAppendingPathComponent:image];
        struct stat state={};
        NSURL *manifest=[generation URLByAppendingPathComponent:@"Package.plist"];
        int lease=open(manifest.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
        BOOL leased=lease>=0 && flock(lease,LOCK_SH|LOCK_NB)==0;
        if (leased && lstat(imageURL.fileSystemRepresentation,&state)==0 && S_ISREG(state.st_mode)) {
            // Keep the shared lease for the lifetime of the factory and its resources.
            path=imageURL.path;
            preparedPaths[name]=path;
            if ([name isEqualToString:@"Surge XT.clap"]) preparedSlots[name]=[NSValue valueWithPointer:&surgeImage];
#if BW_CHOW_EDITOR
            else if ([name isEqualToString:@"CHOWTapeModel.clap"]) preparedSlots[name]=[NSValue valueWithPointer:&chowImage];
#endif
            else preparedSlots[name]=[NSValue valueWithPointer:calloc(1,sizeof(void *))];
        } else if (lease>=0) close(lease);
    }
    if (slot) *slot=preparedSlots[name].pointerValue;
    [loaderLock unlock];
    return path;
}

static BOOL isPreparedImage(NSString *path) {
    NSString *root=BWPreparedPluginRoot().URLByResolvingSymlinksInPath.path;
    return root && [path hasPrefix:[root stringByAppendingString:@"/"]];
}

static NSString *embeddedPluginBinary(CFBundleRef bundle, void ***slot) {
    if (!bundle) return nil;
    NSURL *url=CFBridgingRelease(CFBundleCopyBundleURL(bundle));
    if (BWIndependentPluginsEnabled()) return preparedPluginBinary(url,slot);
    NSURL *app=NSBundle.mainBundle.bundleURL;
    if ([app.pathExtension isEqualToString:@"appex"])
        app=app.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSURL *frameworks=[app URLByAppendingPathComponent:@"Frameworks" isDirectory:YES];
    NSString *path = url.URLByStandardizingPath.path;
    NSString *name = url.lastPathComponent;
    NSString *format = url.pathExtension.uppercaseString;
    if ([format isEqualToString:@"CLAP"] || [format isEqualToString:@"VST3"]) {
        NSURL *managed = [BWManagedPluginRoot() URLByAppendingPathComponent:format isDirectory:YES];
        NSURL *alias = [managed URLByAppendingPathComponent:name];
        if ([path isEqualToString:alias.URLByStandardizingPath.path]) {
            NSURL *approved = [frameworks URLByAppendingPathComponent:name];
            struct stat wrapper = {}, link = {};
            NSURL *contents = [url URLByAppendingPathComponent:@"Contents"];
            NSURL *approvedContents = [approved URLByAppendingPathComponent:@"Contents" isDirectory:YES];
            if (lstat(url.fileSystemRepresentation, &wrapper) != 0 || !S_ISDIR(wrapper.st_mode) ||
                lstat(contents.fileSystemRepresentation, &link) != 0 || !S_ISLNK(link.st_mode) ||
                ![contents.URLByResolvingSymlinksInPath.path isEqualToString:approvedContents.URLByResolvingSymlinksInPath.path])
                return nil;
            path = approved.URLByStandardizingPath.path;
        }
    }
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
    if ([name hasPrefix:@"FabFilter "] && [name hasSuffix:@".clap"] &&
        [path isEqualToString:[frameworks URLByAppendingPathComponent:name].URLByStandardizingPath.path]) {
        NSDictionary *record = fabFilterManifest(frameworks)[name];
        NSString *image = record[@"image"];
        NSNumber *index = record[@"slot"];
        if (image && [image isEqualToString:image.lastPathComponent] && [image hasSuffix:@".bundle"] &&
            index && index.unsignedIntegerValue < sizeof(fabFilterImages) / sizeof(fabFilterImages[0])) {
            if (slot) *slot = &fabFilterImages[index.unsignedIntegerValue];
            return [frameworks URLByAppendingPathComponent:image].path;
        }
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
    if (!isPreparedImage(path) && systemLoad&&systemLoad(bundle,&originalError)) {
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
    NSString *path=embeddedPluginBinary(bundle,&slot);
    if (!path) return systemFunction?systemFunction(bundle,name):NULL;
    [loaderLock lock];
    void *function=*slot?dlsym(*slot,[(__bridge NSString *)name UTF8String]):NULL;
    [loaderLock unlock];
    if (!function && !isPreparedImage(path) && systemFunction) function=systemFunction(bundle,name);
    if (function && isPreparedImage(path) && CFEqual(name,CFSTR("bundleEntry"))) {
        NSString *filename=path.lastPathComponent;
        NSURL *root=[[NSURL fileURLWithPath:path] URLByDeletingLastPathComponent];
        [loaderLock lock];
        if ([filename isEqualToString:@"OTT.bundle"]) {
            if (!preparedOTTBundle) preparedOTTBundle=CFBundleCreate(NULL,(__bridge CFURLRef)[root URLByAppendingPathComponent:@"OTT.vst3"]);
            preparedOTTEntry=function;
            function=preparedOTTBundle ? enterPreparedOTT : NULL;
        } else if ([filename isEqualToString:@"NeuralAmpModeler.bundle"]) {
            if (!preparedNAMBundle) preparedNAMBundle=CFBundleCreate(NULL,(__bridge CFURLRef)[root URLByAppendingPathComponent:@"NeuralAmpModeler.vst3"]);
            preparedNAMEntry=function;
            function=preparedNAMBundle ? enterPreparedNAM : NULL;
        }
        [loaderLock unlock];
    }
#if BW_SURGE_EDITOR
    BOOL surgeEditor = slot == &surgeImage;
#if BW_CHOW_EDITOR
    surgeEditor |= slot == &chowImage;
#endif
    if (function && surgeEditor && CFEqual(name, CFSTR("clap_entry"))) {
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
