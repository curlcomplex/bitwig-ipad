#import "../native/compat/LocalConfiguration.h"
#import <UIKit/UIKit.h>
#import "../native/compat/Trace.h"
#include <dlfcn.h>
#include <jni.h>
#import <objc/message.h>
#import <TargetConditionals.h>
#ifdef EMBEDDED_ENGINE
extern BOOL BWInstallEngineProcessAdapter(JNIEnv *env);
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
    NSString *localCLAP=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/Surge XT.clap"];
    if([NSFileManager.defaultManager fileExistsAtPath:localCLAP]){
        NSString *location=[localCLAP stringByDeletingLastPathComponent];
        setenv("CLAP_PATH",location.fileSystemRepresentation,1);
    }
    NSString *vstFolder=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *name in @[@"OTT.vst3", @"NeuralAmpModeler.vst3"]) {
        if ([NSFileManager.defaultManager fileExistsAtPath:[vstFolder stringByAppendingPathComponent:name]]) {
            setenv("VST3_PATH",vstFolder.fileSystemRepresentation,1);
            break;
        }
    }
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
    NSMutableArray *values = [@[@"-Xint", @"-Xms32m", @"-Xmx512m", @"-XX:+UseSerialGC", @"-XX:ReservedCodeCacheSize=64m",
        [@"-Djava.home=" stringByAppendingString:home],
        [NSString stringWithFormat:@"-Djava.class.path=%@/bitwig.jar:%@/libs.jar", NSBundle.mainBundle.bundlePath, NSBundle.mainBundle.bundlePath],
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
