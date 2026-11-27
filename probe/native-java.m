#import "../native/compat/PluginPackage.h"
#import <UIKit/UIKit.h>
#import "../native/compat/Trace.h"
#include <dlfcn.h>
#include <jni.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#import <objc/message.h>
#import <TargetConditionals.h>
#ifdef EMBEDDED_ENGINE
extern BOOL BWInstallEngineProcessAdapter(JNIEnv *env);

#if BW_INDEPENDENT_PLUGIN_FILES
static void BWCollectRetiredPlugins(NSDictionary *catalog) {
    NSMutableSet *active=[NSMutableSet new];
    for (NSDictionary *entry in catalog.allValues) [active addObject:entry[@"generation"]];
    NSFileManager *files=NSFileManager.defaultManager;
    for (NSURL *folder in [files contentsOfDirectoryAtURL:BWPreparedPluginRoot() includingPropertiesForKeys:nil options:0 error:nil]) {
        if ([active containsObject:folder.lastPathComponent] || ![[NSUUID alloc] initWithUUIDString:folder.lastPathComponent]) continue;
        struct stat state={};
        if (lstat(folder.fileSystemRepresentation,&state)!=0 || !S_ISDIR(state.st_mode)) continue;
        NSURL *manifest=[folder URLByAppendingPathComponent:@"Package.plist"];
        int lease=open(manifest.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
        if (lease<0) continue;
        if (flock(lease,LOCK_EX|LOCK_NB)==0) {
            NSDictionary *info=[NSDictionary dictionaryWithContentsOfURL:manifest];
            if ([info[@"bridgeABI"] isEqual:@1] && [info[@"bundle"] isKindOfClass:NSString.class] &&
                [info[@"image"] isEqual:BWPreparedPluginImageName(info[@"bundle"])])
                [files removeItemAtURL:folder error:nil];
        }
        close(lease);
    }
}

static NSDictionary<NSString *, NSURL *> *BWIndependentPluginLocations(NSSet **changedFormats) {
    NSURL *root=BWManagedPluginRoot();
    if (!root) return nil;
    NSFileManager *files=NSFileManager.defaultManager;
    struct stat state={};
    BOOL existing=lstat(root.fileSystemRepresentation,&state)==0;
    if (existing) {
        if (!S_ISDIR(state.st_mode) ||
            (![files fileExistsAtPath:[root URLByAppendingPathComponent:@".managed-discovery-v1"].path] &&
             ![files fileExistsAtPath:[root URLByAppendingPathComponent:@".independent-discovery-v1"].path])) return nil;
    } else if (errno!=ENOENT) return nil;
    NSDictionary *locations=@{@"CLAP":[root URLByAppendingPathComponent:@"CLAP" isDirectory:YES],
                              @"VST3":[root URLByAppendingPathComponent:@"VST3" isDirectory:YES]};
    NSURL *catalogURL=[root URLByAppendingPathComponent:@".files-catalog-v1.plist"];
    NSDictionary *previous=[NSDictionary dictionaryWithContentsOfURL:catalogURL];
    NSDictionary *catalog=BWPreparedPluginCatalog(previous);
    if (!catalog && existing) return locations;
    if ([catalog isEqual:previous]) {
        BWCollectRetiredPlugins(catalog);
        return locations;
    }
    if (!catalog) catalog=@{}; // Register the stable roots even when Files is temporarily unavailable.
    NSMutableSet *formats=[NSMutableSet new];
    NSMutableSet *names=[NSMutableSet setWithArray:previous.allKeys ?: @[]];
    [names addObjectsFromArray:catalog.allKeys];
    for (NSString *name in names) {
        if (![catalog[name][@"generation"] isEqual:previous[name][@"generation"]])
            [formats addObject:name.pathExtension.uppercaseString];
    }
    if (previous && !formats.count) {
        if ([catalog writeToURL:catalogURL error:nil]) BWCollectRetiredPlugins(catalog);
        return locations;
    }
    NSURL *staging=[root.URLByDeletingLastPathComponent URLByAppendingPathComponent:
        [@"." stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![files createDirectoryAtURL:staging withIntermediateDirectories:NO attributes:nil error:nil]) return nil;
    @try {
        for (NSString *format in @[@"CLAP",@"VST3"]) {
            NSURL *folder=[staging URLByAppendingPathComponent:format isDirectory:YES];
            if (![files createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:nil]) return nil;
        }
        for (NSString *name in catalog) {
            NSString *idString=catalog[name][@"generation"];
            if (![name isKindOfClass:NSString.class] || !BWPreparedPluginImageName(name) ||
                ![idString isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:idString]) return nil;
            NSURL *generation=[BWPreparedPluginRoot() URLByAppendingPathComponent:idString isDirectory:YES];
            NSURL *contents=[[generation URLByAppendingPathComponent:name] URLByAppendingPathComponent:@"Contents"];
            if (lstat(contents.fileSystemRepresentation,&state)!=0 || !S_ISDIR(state.st_mode)) return nil;
            NSURL *folder=[[staging URLByAppendingPathComponent:name.pathExtension.uppercaseString] URLByAppendingPathComponent:name];
            if (![files createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:nil] ||
                ![files createSymbolicLinkAtURL:[folder URLByAppendingPathComponent:@"Contents"] withDestinationURL:contents error:nil])
                return nil;
        }
        if (![catalog writeToURL:[staging URLByAppendingPathComponent:catalogURL.lastPathComponent] error:nil]) return locations;
        NSURL *marker=[staging URLByAppendingPathComponent:@".managed-discovery-v1"];
        if (![[NSData data] writeToURL:marker options:0 error:nil]) return nil;
        if (renamex_np(staging.fileSystemRepresentation,root.fileSystemRepresentation,RENAME_EXCL)!=0 &&
            (errno!=EEXIST || renamex_np(staging.fileSystemRepresentation,root.fileSystemRepresentation,RENAME_SWAP)!=0)) return nil;
        BWCollectRetiredPlugins(catalog);
        if (changedFormats) *changedFormats=formats;
        return locations;
    } @finally {
        [files removeItemAtURL:staging error:nil];
    }
}

#if BW_MANAGED_PLUGIN_REFRESH
@interface BWPreparedPluginPresenter : NSObject <NSFilePresenter>
@property (nonatomic,copy) NSURL *presentedItemURL;
@property (nonatomic,strong) NSOperationQueue *presentedItemOperationQueue;
@property (nonatomic,copy) dispatch_block_t changed;
@end
@implementation BWPreparedPluginPresenter
- (void)presentedItemDidChange { self.changed(); }
- (void)presentedSubitemDidAppearAtURL:(NSURL *)url { self.changed(); }
- (void)presentedSubitemDidChangeAtURL:(NSURL *)url { self.changed(); }
- (void)presentedSubitemAtURL:(NSURL *)oldURL didMoveToURL:(NSURL *)newURL { self.changed(); }
- (void)accommodatePresentedSubitemDeletionAtURL:(NSURL *)url completionHandler:(void (^)(NSError *))completion {
    completion(nil);
    self.changed();
}
- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completion {
    completion(nil);
    self.changed();
}
@end

static void BWWatchPreparedPluginFolder(JavaVM *vm, JNIEnv *env) {
    jclass helper=(*env)->FindClass(env,"ManagedPluginRefresh");
    jmethodID request=helper ? (*env)->GetStaticMethodID(env,helper,"request","(Ljava/lang/String;Ljava/lang/String;)V") : NULL;
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
    if (!request) return;
    jclass refresh=(*env)->NewGlobalRef(env,helper);
    if (!refresh) return;
    dispatch_queue_t queue=dispatch_queue_create("org.bitwigipad.plugin-files",DISPATCH_QUEUE_SERIAL);
    NSMutableSet *pending=[NSMutableSet new];
    __block NSUInteger revision=0;
    dispatch_block_t schedule=^{
        dispatch_async(queue, ^{
            NSUInteger expected=++revision;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),queue, ^{ @autoreleasepool {
                if (expected!=revision) return;
                NSSet *changed=nil;
                NSDictionary<NSString *,NSURL *> *locations=BWIndependentPluginLocations(&changed);
                if (changed) [pending unionSet:changed];
                if (!locations) return;
                JNIEnv *threadEnv=NULL;
                if ((*vm)->AttachCurrentThreadAsDaemon(vm,(void **)&threadEnv,NULL)!=JNI_OK) return;
                jstring clap=[pending containsObject:@"CLAP"] ? (*threadEnv)->NewStringUTF(threadEnv,locations[@"CLAP"].fileSystemRepresentation) : NULL;
                jstring vst3=[pending containsObject:@"VST3"] ? (*threadEnv)->NewStringUTF(threadEnv,locations[@"VST3"].fileSystemRepresentation) : NULL;
                (*threadEnv)->CallStaticVoidMethod(threadEnv,refresh,request,clap,vst3);
                if ((*threadEnv)->ExceptionCheck(threadEnv)) {
                    (*threadEnv)->ExceptionDescribe(threadEnv);
                    (*threadEnv)->ExceptionClear(threadEnv);
                } else [pending removeAllObjects];
                (*vm)->DetachCurrentThread(vm);
            }});
        });
    };
    static BWPreparedPluginPresenter *presenter;
    presenter=[BWPreparedPluginPresenter new];
    presenter.presentedItemURL=BWPreparedPluginFilesFolder();
    presenter.presentedItemOperationQueue=[NSOperationQueue new];
    presenter.presentedItemOperationQueue.maxConcurrentOperationCount=1;
    presenter.changed=schedule;
    __block BOOL presenting=NO;
    void (^startPresenting)(void)=^{
        if (presenting || !presenter.presentedItemURL) return;
        [NSFileCoordinator addFilePresenter:presenter];
        presenting=YES;
    };
    NSNotificationCenter *notifications=NSNotificationCenter.defaultCenter;
    [notifications addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            startPresenting();
            schedule();
        }];
    [notifications addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            if (presenting) {
                [NSFileCoordinator removeFilePresenter:presenter];
                presenting=NO;
            }
        }];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground) startPresenting();
    });
}
#endif
#endif

static NSDictionary<NSString *, NSURL *> *BWRefreshManagedPlugins(NSURL *frameworks) {
    NSURL *root = BWManagedPluginRoot();
    if (!root) return nil;

    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableArray *clap = [@[@"Surge XT.clap", @"CHOWTapeModel.clap"] mutableCopy];
    NSURL *manifestURL = [frameworks URLByAppendingPathComponent:@"fabfilter-clap.json"];
    NSData *data = [NSData dataWithContentsOfURL:manifestURL];
    id manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([manifest isKindOfClass:NSDictionary.class]) {
        for (NSString *name in manifest) {
            if ([name isEqualToString:name.lastPathComponent] &&
                [name hasPrefix:@"FabFilter "] && [name.pathExtension isEqualToString:@"clap"])
                [clap addObject:name];
        }
    }
    NSDictionary<NSString *, NSArray<NSString *> *> *bundles = @{
        @"CLAP":clap, @"VST3":@[@"OTT.vst3", @"NeuralAmpModeler.vst3"],
    };

    NSString *ownerFile = @".managed-discovery-v1";
    struct stat state = {};
    if (lstat(root.fileSystemRepresentation, &state) == 0) {
        if (!S_ISDIR(state.st_mode) || ![files fileExistsAtPath:[root URLByAppendingPathComponent:ownerFile].path]) return nil;
    } else if (errno != ENOENT) {
        return nil;
    }

    NSURL *parent = root.URLByDeletingLastPathComponent;
    NSString *name = [@"." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURL *staging = [parent URLByAppendingPathComponent:name isDirectory:YES];
    if (![files createDirectoryAtURL:staging withIntermediateDirectories:NO attributes:nil error:nil]) return nil;
    @try {
        NSMutableDictionary<NSString *, NSURL *> *discovery = [NSMutableDictionary new];
        for (NSString *format in bundles) {
            NSURL *folder = [staging URLByAppendingPathComponent:format isDirectory:YES];
            for (NSString *bundle in bundles[format]) {
                NSURL *target = [frameworks URLByAppendingPathComponent:bundle isDirectory:YES];
                BOOL directory = NO;
                if (![files fileExistsAtPath:target.path isDirectory:&directory] || !directory) continue;
                if (!discovery[format]) {
                    if (![files createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:nil]) return nil;
                    discovery[format] = [root URLByAppendingPathComponent:format isDirectory:YES];
                }
                NSURL *alias = [folder URLByAppendingPathComponent:bundle];
                if (![files createDirectoryAtURL:alias withIntermediateDirectories:NO attributes:nil error:nil]) return nil;
                alias = [alias URLByAppendingPathComponent:@"Contents"];
                target = [target URLByAppendingPathComponent:@"Contents" isDirectory:YES];
                if (![files fileExistsAtPath:target.path isDirectory:&directory] || !directory) return nil;
                if (![files createSymbolicLinkAtURL:alias withDestinationURL:target error:nil]) return nil;
            }
        }
        NSURL *owner = [staging URLByAppendingPathComponent:ownerFile];
        if (![[NSData data] writeToURL:owner options:0 error:nil]) return nil;
        // Publish a fully populated catalog in one filesystem operation.
        if (renamex_np(staging.fileSystemRepresentation, root.fileSystemRepresentation, RENAME_EXCL) != 0 &&
            (errno != EEXIST || renamex_np(staging.fileSystemRepresentation, root.fileSystemRepresentation, RENAME_SWAP) != 0))
            return nil;
        return discovery;
    } @finally {
        [files removeItemAtURL:staging error:nil];
    }
}
#endif

#ifdef STATIC_ZERO
#ifndef SOURCE_ZERO
extern void loadfunctions(void);
#endif
extern int csops(pid_t, unsigned int, void *, size_t);
static id debuggerAttached(void) {
    unsigned int flags=0;
    return csops(getpid(),0,&flags,sizeof(flags))==0 ? @((flags & 0x10000000)!=0) : NSNull.null;
}
#endif
#if !TARGET_OS_SIMULATOR && defined(FULL_BITWIG_HOST) && !defined(STATIC_ZERO)
__attribute__((visibility("default"))) bool DeviceHasTXM(void) { return true; }
__attribute__((naked,noinline)) static void detachEmbeddedJIT(void) { __asm__("mov x16, #0\n brk #0xf00d\n ret"); }
#endif

static void captureNativeException(NSException *exception) {
    BWCompatibilityTrace("exception", "frontend", exception.name.UTF8String, "uncaught");
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *description=[NSString stringWithFormat:@"%@\n%@\n",exception,exception.callStackSymbols];
    [description writeToFile:[documents stringByAppendingPathComponent:@"native-exception.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#if !TARGET_OS_SIMULATOR && defined(FULL_BITWIG_HOST)
static jstring readIOSRegistryString(JNIEnv *env, jclass cls, jstring key) {
    const char *name=(*env)->GetStringUTFChars(env,key,NULL);
    if(!name)return NULL;
    BOOL isDeviceID=strcmp(name,"IOPlatformUUID")==0;
    (*env)->ReleaseStringUTFChars(env,key,name);
    if(!isDeviceID) {
        // Preserve the original implementation for any other registry lookup.
        void *image=dlopen([[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libbitwig-jni.jnilib"] fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
        jstring (*original)(JNIEnv*,jclass,jstring)=dlsym(image,"Java_com_bitwig_base_platform_MacOsXIoKit_readRegistryStringValue");
        jstring result=original(env,cls,key);dlclose(image);return result;
    }
    // iPadOS does not expose macOS's IOPlatformUUID. Its vendor-scoped device
    // identifier supplies a real, stable app identity, not another Mac's UUID.
    __block NSString *identifier;
    void (^read)(void)=^{identifier=UIDevice.currentDevice.identifierForVendor.UUIDString;};
    if(NSThread.isMainThread)read();else dispatch_sync(dispatch_get_main_queue(),read);
    if(!identifier) {
        (*env)->ThrowNew(env,(*env)->FindClass(env,"java/lang/IllegalStateException"),"iPadOS device identifier is unavailable");
        return NULL;
    }
    return (*env)->NewStringUTF(env,identifier.UTF8String);
}
#endif

#ifdef FULL_BITWIG_HOST
static void (*originalTextInputSession)(JNIEnv*,jclass,jobject);
static void (*setUIKitTextInputActive)(BOOL);
static void setIOSTextInputSession(JNIEnv *env,jclass cls,jobject session) {
    originalTextInputSession(env,cls,session);
    fprintf(stdout,"[UIKit text] session active=%d\n",session!=NULL);
    setUIKitTextInputActive(session!=NULL);
}
#endif

static void runJava(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    [NSFileManager.defaultManager removeItemAtPath:[documents stringByAppendingPathComponent:@"native-exception.txt"] error:nil];
    freopen([[documents stringByAppendingPathComponent:@"native-java.log"] fileSystemRepresentation], "w", stdout);
    freopen([[documents stringByAppendingPathComponent:@"native-java-errors.log"] fileSystemRepresentation], "w", stderr);
    setvbuf(stdout, NULL, _IONBF, 0); setvbuf(stderr, NULL, _IONBF, 0);
    NSString *home = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"jre"];
#ifdef STATIC_ZERO
    home = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"lib"];
#endif
    NSMutableDictionary *report = [@{@"scope": @"iOS Simulator Java 25 runtime and real Bitwig class loading; not full application execution", @"phase": @"loading JVM"} mutableCopy];
#ifdef STATIC_ZERO
    report[@"scope"]=@"Statically signed OpenJDK Zero runtime and real Bitwig class loading; no JIT helper";
    report[@"debugger_attached_before"]=debuggerAttached();
    report[@"pid"]=@(getpid());
#endif
    void (^save)(void) = ^{
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"native-java.json"] atomically:YES];
    };
    save();
    NSString *userHome=documents;
#ifdef EMBEDDED_ENGINE
    NSURL *shared=BWSharedContainerURL();
    if(!shared){report[@"phase"]=@"shared engine container unavailable";save();return;}
    userHome=[[shared URLByAppendingPathComponent:@"BitwigUser"] path];
    NSError *sharedError=nil;
    if(![NSFileManager.defaultManager createDirectoryAtPath:userHome withIntermediateDirectories:YES attributes:nil error:&sharedError]){
        report[@"phase"]=@"shared engine home creation failed";
        report[@"engine_shared_home"]=userHome;report[@"error"]=sharedError.description;save();return;
    }
    // Preserve the prototype's existing preferences; pairing records stay private.
    NSString *oldLibrary=[documents stringByAppendingPathComponent:@"Library"];
    NSString *newLibrary=[userHome stringByAppendingPathComponent:@"Library"];
    if([NSFileManager.defaultManager fileExistsAtPath:oldLibrary]&&![NSFileManager.defaultManager fileExistsAtPath:newLibrary])
        [NSFileManager.defaultManager copyItemAtPath:oldLibrary toPath:newLibrary error:nil];
    NSString *posix=[userHome stringByAppendingPathComponent:@"Posix/Frontend"];
    [NSFileManager.defaultManager createDirectoryAtPath:posix withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("BITWIG_PROCESS_POSIX_RESOURCE_FOLDER",posix.fileSystemRepresentation,1);
    report[@"engine_shared_home"]=userHome;save();
#endif
#ifdef FULL_BITWIG_HOST
    NSArray *imports=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"native-imports" ofType:@"json"]] options:0 error:nil];
    NSMutableArray *scan=[NSMutableArray new];
    for (NSDictionary *item in imports) {
        NSString *path=item[@"library"];
        path=[path stringByReplacingOccurrencesOfString:@"@rpath/" withString:[NSBundle.mainBundle.bundlePath stringByAppendingString:@"/Frameworks/"]];
        path=[path stringByReplacingOccurrencesOfString:@"@loader_path/" withString:[NSBundle.mainBundle.bundlePath stringByAppendingString:@"/Frameworks/"]];
        void *h=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
        const char *error=h?NULL:dlerror();
        NSMutableArray *missing=[NSMutableArray new];
        for(NSString *symbol in item[@"symbols"]) if(!h||!dlsym(h,symbol.UTF8String)) [missing addObject:symbol];
        [scan addObject:@{@"library":path,@"error":error?@(error):@"",@"missing":missing}];
    }
    [[NSJSONSerialization dataWithJSONObject:scan options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"native-host-symbols.json"] atomically:YES];
    report[@"scope"]=@"Native Bitwig application startup through UIKit compatibility host";
    void *nativeImage=dlopen([[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libbitwig-jni.jnilib"] fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
    report[@"native_image_loaded"]=@(nativeImage!=NULL);
    if(!nativeImage) { const char *error=dlerror();report[@"native_image_error"]=error?@(error):@"unknown load error"; }
    BWCompatibilityTrace("dlopen", "frontend", "libbitwig-jni.jnilib", nativeImage ? "loaded" : "failed");
    save();
    void (*prepareMetal)(void)=dlsym(nativeImage,"BWUIKitPrepareMetal");
    BWCompatibilityTrace("dlsym", "frontend", "BWUIKitPrepareMetal", prepareMetal ? "resolved" : "missing");
    if(prepareMetal)prepareMetal();
#endif
    // Simulator runs on the Mac kernel; do not request physical-device TXM debugging.
#if TARGET_OS_SIMULATOR
    setenv("XNU_HAS_TXM", "0", 1);
#elif defined(FULL_BITWIG_HOST) && !defined(STATIC_ZERO)
    setenv("XNU_HAS_TXM", "1", 1);
    report[@"phase"]=@"waiting for embedded JIT helper";save();
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);
    __block BOOL prepared=NO;
    dispatch_async(dispatch_get_main_queue(),^{
        Class coordinator=NSClassFromString(@"NativeJITCoordinator");
        void (^completion)(BOOL)=^(BOOL success){prepared=success;dispatch_semaphore_signal(ready);};
        if(coordinator)((void(*)(id,SEL,id))objc_msgSend)(coordinator,@selector(startWithCompletion:),completion);
        else completion(NO);
    });
    dispatch_semaphore_wait(ready,DISPATCH_TIME_FOREVER);
    if(!prepared){report[@"phase"]=@"embedded JIT unavailable";save();return;}
#endif
#ifdef EMBEDDED_ENGINE
    NSURL *frameworks = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Frameworks" isDirectory:YES];
#if BW_INDEPENDENT_PLUGIN_FILES
    NSDictionary<NSString *, NSURL *> *discovery = BWIndependentPluginLocations(NULL);
#else
    NSDictionary<NSString *, NSURL *> *discovery = BWRefreshManagedPlugins(frameworks);
#endif
    for (NSString *format in discovery)
        setenv([[format stringByAppendingString:@"_PATH"] UTF8String], discovery[format].fileSystemRepresentation, 1);
#endif
    setenv("JAVA_HOME", home.fileSystemRepresentation, 1);
#ifdef STATIC_ZERO
#ifndef SOURCE_ZERO
    loadfunctions();
#endif
    jint (*create)(JavaVM**, void**, void*) = JNI_CreateJavaVM;
#else
    void *library = dlopen([[home stringByAppendingPathComponent:@"lib/server/libjvm.dylib"] fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL);
    if (!library) { report[@"error"] = @(dlerror()); BWCompatibilityTrace("dlopen", "frontend", "libjvm.dylib", "failed"); save(); return; }
    BWCompatibilityTrace("dlopen", "frontend", "libjvm.dylib", "loaded");
    jint (*create)(JavaVM**, void**, void*) = dlsym(library, "JNI_CreateJavaVM");
    BWCompatibilityTrace("dlsym", "frontend", "JNI_CreateJavaVM", create ? "resolved" : "missing");
    if (!create) { report[@"error"] = @"JNI_CreateJavaVM not exported"; save(); return; }
#endif
    NSString *appBundle = NSBundle.mainBundle.bundlePath;
    NSString *classpath = [NSString stringWithFormat:@"%@/bitwig.jar:%@/libs.jar", appBundle, appBundle];
#if defined(GRID_RATE_OVERLAY)
    NSString *overlay = [NSBundle.mainBundle pathForResource:@"GridRate" ofType:@"jar"];
    if (!overlay) { report[@"error"] = @"Grid rate overlay missing"; save(); return; }
    classpath = [NSString stringWithFormat:@"%@:%@", overlay, classpath];
#endif
#if BW_MANAGED_PLUGIN_REFRESH
    NSString *refreshJar=[NSBundle.mainBundle pathForResource:@"ManagedPluginRefresh" ofType:@"jar"];
    if (refreshJar) classpath=[NSString stringWithFormat:@"%@:%@",refreshJar,classpath];
#endif
    NSMutableArray *values = [@[@"-Xint", @"-Xms32m", @"-Xmx512m", @"-XX:+UseSerialGC", @"-XX:ReservedCodeCacheSize=64m",
        [@"-Djava.home=" stringByAppendingString:home],
        [@"-Djava.class.path=" stringByAppendingString:classpath],
        [NSString stringWithFormat:@"-XX:ErrorFile=%@/hs_err.log", documents]] mutableCopy];
#if defined(FULL_BITWIG_HOST) && !defined(STATIC_ZERO)
    if (BWCompatibilityTracing()) {
        [values addObject:[NSString stringWithFormat:
            @"-Xlog:library=debug,jni+resolve=debug:file=%@/native-compat-jvm.log:uptime,tags:filecount=2,filesize=128K",
            documents]];
    }
#endif
#if !TARGET_OS_SIMULATOR && defined(FULL_BITWIG_HOST) && !defined(STATIC_ZERO)
    report[@"execution_mode"]=@"interpreter";
    if(![NSProcessInfo.processInfo.arguments containsObject:@"--native-java-interpreter"]){
        report[@"execution_mode"]=@"C1 JIT, mirrored code cache";
        [values removeObject:@"-Xint"];
        [values addObject:@"-XX:TieredStopAtLevel=1"];
        [values addObject:[NSString stringWithFormat:@"-Xlog:jit+compilation=debug:file=%@/native-java-compilation.log:uptime,level,tags:filecount=1,filesize=2M",documents]];
    }
#endif
#ifdef FULL_BITWIG_HOST
    [values addObjectsFromArray:@[@"--enable-native-access=ALL-UNNAMED", @"-Dos.name=Mac OS X", [@"-DinstallationRoot=" stringByAppendingString:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"installation"]],
        [@"-Duser.home=" stringByAppendingString:userHome], [@"-Duser.dir=" stringByAppendingString:userHome],
        [NSString stringWithFormat:@"-Djna.boot.library.path=%@/Frameworks",NSBundle.mainBundle.bundlePath],
        [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks",NSBundle.mainBundle.bundlePath]]];
#else
    [values addObject:@"-Djava.awt.headless=true"];
#endif
#if !TARGET_OS_SIMULATOR && defined(FULL_BITWIG_HOST) && !defined(STATIC_ZERO)
    [values addObject:@"-XX:+MirrorMappedCodeCache"];
#endif
    JavaVMOption options[values.count];
    for (NSUInteger i=0; i<values.count; i++) { options[i].optionString = (char*)[values[i] UTF8String]; options[i].extraInfo = NULL; }
    JavaVMInitArgs arguments = {JNI_VERSION_1_8, (jint)values.count, options, JNI_FALSE};
    JavaVM *vm = NULL; JNIEnv *env = NULL;
    report[@"phase"] = @"creating JVM"; save();
    jint rc = create(&vm, (void**)&env, &arguments);
    report[@"create_result"] = @(rc); save();
    if (rc != JNI_OK) {
#if !TARGET_OS_SIMULATOR && defined(FULL_BITWIG_HOST) && !defined(STATIC_ZERO)
        detachEmbeddedJIT();
#endif
        return;
    }
#if !TARGET_OS_SIMULATOR && defined(FULL_BITWIG_HOST) && !defined(STATIC_ZERO)
    detachEmbeddedJIT();
#endif
    jclass system = (*env)->FindClass(env, "java/lang/System");
    jmethodID property = (*env)->GetStaticMethodID(env, system, "getProperty", "(Ljava/lang/String;)Ljava/lang/String;");
    jstring key = (*env)->NewStringUTF(env, "java.version");
    jstring version = (*env)->CallStaticObjectMethod(env, system, property, key);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); report[@"error"]=@"Reading runtime version failed"; save(); return; }
    const char *utf = (*env)->GetStringUTFChars(env, version, NULL);
    report[@"java_version"] = @(utf); (*env)->ReleaseStringUTFChars(env, version, utf);
#ifdef STATIC_ZERO
    report[@"debugger_attached_after"]=debuggerAttached();
    key=(*env)->NewStringUTF(env,"java.vm.name");
    jstring vmName=(*env)->CallStaticObjectMethod(env,system,property,key);
    if(vmName&&!(*env)->ExceptionCheck(env)) {
        utf=(*env)->GetStringUTFChars(env,vmName,NULL);
        report[@"java_vm_name"]=@(utf);(*env)->ReleaseStringUTFChars(env,vmName,utf);
    }
#endif
#ifdef FULL_BITWIG_HOST
    NSSetUncaughtExceptionHandler(captureNativeException);
#ifdef EMBEDDED_ENGINE
    if(!BWInstallEngineProcessAdapter(env)){
        if((*env)->ExceptionCheck(env))(*env)->ExceptionDescribe(env);
        report[@"phase"]=@"embedded engine process adapter failed";save();return;
    }
    report[@"engine_process_adapter"]=@"native extension";
#if BW_MANAGED_PLUGIN_REFRESH
    BWWatchPreparedPluginFolder(vm,env);
#endif
#endif
#if !TARGET_OS_SIMULATOR
    jclass ioKit=(*env)->FindClass(env,"com/bitwig/base/platform/MacOsXIoKit");
    JNINativeMethod registryMethod={"readRegistryStringValue","(Ljava/lang/String;)Ljava/lang/String;",(void*)readIOSRegistryString};
    if(!ioKit||(*env)->RegisterNatives(env,ioKit,&registryMethod,1)!=JNI_OK) {
        if((*env)->ExceptionCheck(env))(*env)->ExceptionDescribe(env);
        report[@"phase"]=@"iPad device identity adapter failed";save();return;
    }
    report[@"device_identity_api"]=@"UIDevice.identifierForVendor";
#endif
    originalTextInputSession=dlsym(nativeImage,"Java_com_bitwig_mac_1windowing_1system_CocoaDisplay_setCocoaTextInputSession");
    setUIKitTextInputActive=dlsym(nativeImage,"BWUIKitSetTextInputActive");
    jclass cocoaDisplay=(*env)->FindClass(env,"com/bitwig/mac_windowing_system/CocoaDisplay");
    JNINativeMethod textInputMethod={"setCocoaTextInputSession","(Lcom/bitwig/mac_windowing_system/CocoaTextInputSession;)V",(void*)setIOSTextInputSession};
    if(!originalTextInputSession||!setUIKitTextInputActive||!cocoaDisplay||(*env)->RegisterNatives(env,cocoaDisplay,&textInputMethod,1)!=JNI_OK){
        if((*env)->ExceptionCheck(env))(*env)->ExceptionDescribe(env);
        report[@"phase"]=@"iPad text input adapter failed";save();return;
    }
    report[@"phase"]=@"initializing BitwigStudioMain";save();
    jclass mainClass=(*env)->FindClass(env,"com/bitwig/flt/app/BitwigStudioMain");
    if(mainClass&&!(*env)->ExceptionCheck(env)) {
        jmethodID main=(*env)->GetStaticMethodID(env,mainClass,"main","([Ljava/lang/String;)V");
        jclass stringClass=(*env)->FindClass(env,"java/lang/String");
        jobjectArray args=(*env)->NewObjectArray(env,0,stringClass,NULL);
        if(main&&!(*env)->ExceptionCheck(env)) {
            report[@"phase"]=@"running BitwigStudioMain.main";save();
            (*env)->CallStaticVoidMethod(env,mainClass,main,args);
        }
    }
    if((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env);(*env)->ExceptionClear(env);report[@"phase"]=@"Bitwig startup threw an exception"; }
    else report[@"phase"]=@"Bitwig main returned";
    save();
    (*vm)->DetachCurrentThread(vm);
    return;
#endif
    jclass loaderClass = (*env)->FindClass(env, "java/lang/ClassLoader");
    jmethodID getLoader = (*env)->GetStaticMethodID(env, loaderClass, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
    jobject loader = (*env)->CallStaticObjectMethod(env, loaderClass, getLoader);
    jclass classClass = (*env)->FindClass(env, "java/lang/Class");
    jmethodID forName = (*env)->GetStaticMethodID(env, classClass, "forName", "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;");
    // The distribution's manifest names an entry point absent after obfuscation.
    // Platform.class is present in the actual archive and has class-file major 69.
    jstring name = (*env)->NewStringUTF(env, "com.bitwig.base.platform.Platform");
    jobject entry = (*env)->CallStaticObjectMethod(env, classClass, forName, name, JNI_FALSE, loader);
    bool exception = (*env)->ExceptionCheck(env);
    report[@"bitwig_class"] = @"com.bitwig.base.platform.Platform";
    report[@"bitwig_class_loaded_without_initialization"] = @(entry != NULL && !exception);
    if (exception) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
    report[@"phase"] = @"finished"; save();
    (*vm)->DetachCurrentThread(vm);
}
@interface JavaProbeScene : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow *window;
@end
@implementation JavaProbeScene
- (void)recordLifecycle:(NSString *)phase {
    NSLog(@"Native scene %@",phase);
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSDictionary *state=@{@"pid":@(getpid()),@"phase":phase,@"time":@([NSDate date].timeIntervalSince1970),@"application_state":@(UIApplication.sharedApplication.applicationState)};
    [[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"native-lifecycle.json"] atomically:YES];
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    [self recordLifecycle:@"active"];
    UIApplication.sharedApplication.idleTimerDisabled=[NSProcessInfo.processInfo.arguments containsObject:@"--native-ui-automation"];
}
- (void)sceneWillResignActive:(UIScene *)scene {
    [self recordLifecycle:@"resigning active"];
    UIApplication.sharedApplication.idleTimerDisabled=NO;
}
- (void)sceneDidEnterBackground:(UIScene *)scene { [self recordLifecycle:@"background"]; }
- (void)sceneWillEnterForeground:(UIScene *)scene { [self recordLifecycle:@"entering foreground"]; }
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc=[UIViewController new]; vc.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(40,80,700,100)]; label.text=@"Native Java 25 / Bitwig class-loading probe"; [vc.view addSubview:label];
#ifdef FULL_BITWIG_HOST
    vc.view.backgroundColor=[UIColor colorWithWhite:0.12 alpha:1];
    label.text=@"Starting Bitwig…";label.textColor=UIColor.whiteColor;label.numberOfLines=0;
    label.frame=CGRectMake(32,80,MIN(((UIWindowScene*)scene).coordinateSpace.bounds.size.width-64,650),180);
    UIButton *retry=[UIButton buttonWithType:UIButtonTypeSystem];retry.frame=CGRectMake(32,270,220,50);
    __block BOOL needsTunnelConsent=NO;
    [retry setTitle:@"Retry startup" forState:UIControlStateNormal];retry.hidden=YES;[vc.view addSubview:retry];
    [retry addAction:[UIAction actionWithHandler:^(UIAction *action){
        retry.hidden=YES;label.text=@"Starting Bitwig…";
        void (^launch)(void)=^{NSThread *worker=[[NSThread alloc] initWithBlock:^{runJava();}];worker.stackSize=8*1024*1024;[worker start];};
        if(needsTunnelConsent) {
            Class coordinator=NSClassFromString(@"NativeJITCoordinator");
            void (^completion)(BOOL)=^(BOOL success){if(success)launch();};
            ((void(*)(id,SEL,id))objc_msgSend)(coordinator,@selector(authorizeTunnelWithCompletion:),completion);
        } else launch();
    }] forControlEvents:UIControlEventTouchUpInside];
    [NSNotificationCenter.defaultCenter addObserverForName:@"NativeHostStatus" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification){
        label.text=notification.object;
        needsTunnelConsent=[notification.userInfo[@"phase"] isEqual:@"needsTunnelConsent"];
        [retry setTitle:needsTunnelConsent?@"Enable local tunnel":@"Retry startup" forState:UIControlStateNormal];
        retry.hidden=![@[@"failed",@"blocked",@"needsTunnelConsent"] containsObject:notification.userInfo[@"phase"]];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"NSWindowDidBecomeKeyNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification){
        // Once the original frontend is visible, keep the backdrop clear.
        label.hidden=YES;retry.hidden=YES;
    }];
#endif
    self.window.rootViewController=vc; [self.window makeKeyAndVisible];
#if BW_SURGE_REMOTE
    __weak UIWindowScene *weakScene = (UIWindowScene *)scene;
    NSTimer *editorTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        UIWindowScene *current = weakScene;
        if (!current) { [timer invalidate]; return; }
        if (current.activationState != UISceneActivationStateForegroundActive) return;
        NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libBitwigUIKit.dylib"];
        void *bridge = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_NOLOAD);
        if (!bridge) return;
        void (*poll)(UIWindowScene *) = dlsym(bridge, "BWPollDetachedEditors");
        if (poll) poll(current);
        dlclose(bridge);
    }];
    [NSRunLoop.mainRunLoop addTimer:editorTimer forMode:NSRunLoopCommonModes];
#endif
#ifdef FULL_BITWIG_HOST
    if([NSProcessInfo.processInfo.arguments containsObject:@"--native-ui-automation"]){
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer){
            // JNI loads its dependencies with local symbol visibility.
            NSString *path=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libBitwigUIKit.dylib"];
            void *bridge=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_NOLOAD);
            if(bridge){void (*poll)(void)=dlsym(bridge,"BWUIKitPollTestInput");if(poll)poll();dlclose(bridge);}
        }];
    }
#endif
    NSThread *worker=[[NSThread alloc] initWithBlock:^{runJava();}]; worker.stackSize=8*1024*1024; [worker start];
}
@end
@interface JavaProbeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation JavaProbeDelegate
- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder {
    [super buildMenuWithBuilder:builder];
#ifdef FULL_BITWIG_HOST
    void (*build)(id<UIMenuBuilder>)=dlsym(RTLD_DEFAULT,"BWUIKitBuildMenu");if(build)build(builder);
#endif
}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *c=[[UISceneConfiguration alloc] initWithName:@"Probe" sessionRole:session.role]; c.delegateClass=JavaProbeScene.class; return c;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(JavaProbeDelegate.class)); } }
