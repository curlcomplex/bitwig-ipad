#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <jni.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <sys/param.h>

// ProcessImpl adapter for this app's embedded Bitwig engine and metadata helper.
// All other subprocess calls retain the original JDK implementation.
static NSCondition *condition;
static NSMutableDictionary<NSNumber*,NSMutableDictionary*> *processes,*metadataProcesses;
static void prepareRegistry(void){static dispatch_once_t once;dispatch_once(&once,^{condition=[NSCondition new];processes=[NSMutableDictionary new];metadataProcesses=[NSMutableDictionary new];});}
void BWEngineProcessStarted(int pid){if(pid<=0)return;prepareRegistry();[condition lock];[metadataProcesses removeObjectForKey:@(pid)];processes[@(pid)]=[@{@"exited":@NO} mutableCopy];[condition broadcast];[condition unlock];}
void BWEngineProcessExited(int pid,int code){if(pid<=0)return;prepareRegistry();[condition lock];if(processes[@(pid)]){processes[@(pid)][@"exited"]=@YES;processes[@(pid)][@"code"]=@(code);}[condition broadcast];[condition unlock];}
void BWPluginMetadataProcessStarted(int pid) {
    if(pid<=0)return;
    prepareRegistry();
    [condition lock];
    [processes removeObjectForKey:@(pid)];
    metadataProcesses[@(pid)]=[@{@"exited":@NO} mutableCopy];
    [condition broadcast];
    [condition unlock];
}
void BWPluginMetadataProcessExited(int pid,int code) {
    if(pid<=0)return;
    prepareRegistry();
    [condition lock];
    [metadataProcesses[@(pid)] addEntriesFromDictionary:@{@"exited":@YES,@"code":@(code)}];
    [condition broadcast];
    [condition unlock];
}
static BOOL tracked(jlong pid){prepareRegistry();[condition lock];BOOL found=processes[@(pid)]!=nil||metadataProcesses[@(pid)]!=nil;[condition unlock];return found;}
static jint (*originalFork)(JNIEnv*,jobject,jint,jbyteArray,jbyteArray,jbyteArray,jint,jbyteArray,jint,jbyteArray,jintArray,jboolean);
static jint (*originalWait)(JNIEnv*,jclass,jlong,jboolean);
static jlong (*originalAlive)(JNIEnv*,jobject,jlong);
static jboolean (*originalDestroy)(JNIEnv*,jobject,jlong,jlong,jboolean);
static NSArray<NSString*> *strings(JNIEnv *env,jbyteArray array){
    if(!array)return @[];
    jsize size=(*env)->GetArrayLength(env,array);NSMutableData *data=[NSMutableData dataWithLength:size];
    (*env)->GetByteArrayRegion(env,array,0,size,data.mutableBytes);
    NSMutableArray *result=[NSMutableArray new];const char *bytes=data.bytes;NSUInteger start=0;
    for(NSUInteger i=0;i<size;i++)if(bytes[i]==0){NSString *value=[[NSString alloc] initWithBytes:bytes+start length:i-start encoding:NSUTF8StringEncoding];if(value)[result addObject:value];start=i+1;}
    if(start<size){NSString *value=[[NSString alloc] initWithBytes:bytes+start length:size-start encoding:NSUTF8StringEncoding];if(value)[result addObject:value];}
    return result;
}
static jint launchMetadata(JNIEnv *env,jintArray fds,NSArray<NSString *> *arguments) {
    Class coordinator=NSClassFromString(@"NativePluginMetadataCoordinator");
    if(!coordinator||NSThread.isMainThread||arguments.count!=4||![arguments.firstObject isEqualToString:@"metadata"]){
        (*env)->ThrowNew(env,(*env)->FindClass(env,"java/io/IOException"),"Unsupported iPad plug-in helper mode");
        return -1;
    }
    jint requested[3];(*env)->GetIntArrayRegion(env,fds,0,3,requested);
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);
    __block int pid=0;
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^completed)(int)=^(int value){pid=value;dispatch_semaphore_signal(ready);};
        ((void(*)(id,SEL,id,id))objc_msgSend)(coordinator,NSSelectorFromString(@"startWithArguments:completion:"),arguments,completed);
    });
    dispatch_semaphore_wait(ready,DISPATCH_TIME_FOREVER);
    if(pid<=0){
        (*env)->ThrowNew(env,(*env)->FindClass(env,"java/io/IOException"),"Embedded Bitwig plug-in metadata process could not start");
        return -1;
    }
    // The metadata protocol is on the original TCP connection. The helper
    // writes its diagnostics to its own container.
    jint returned[3];
    for(int i=0;i<3;i++)returned[i]=requested[i]==-1?open("/dev/null",i==0?O_WRONLY:O_RDONLY):-1;
    (*env)->SetIntArrayRegion(env,fds,0,3,returned);
    return pid;
}
static jint launchEngine(JNIEnv *env,jobject object,jint mode,jbyteArray helper,jbyteArray program,jbyteArray block,jint argc,jbyteArray environment,jint envc,jbyteArray directory,jintArray fds,jboolean merge){
    NSString *path=strings(env,program).firstObject;
    NSString *expected=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"installation/Contents/MacOS/Bitwig Audio Engine ARM64-NEON.app/Contents/MacOS/BitwigAudioEngine-ARM64-NEON"];
    NSString *metadata=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"installation/Contents/MacOS/Bitwig Plug-in Host ARM64-NEON.app/Contents/MacOS/BitwigPluginHost-ARM64-NEON"];
    if(NSClassFromString(@"NativePluginMetadataCoordinator")&&[path isEqualToString:metadata])
        return launchMetadata(env,fds,strings(env,block));
    if(![path isEqualToString:expected])return originalFork(env,object,mode,helper,program,block,argc,environment,envc,directory,fds,merge);
    if(NSThread.isMainThread){(*env)->ThrowNew(env,(*env)->FindClass(env,"java/io/IOException"),"Engine launch must run outside the UIKit thread");return -1;}
    NSArray *arguments=strings(env,block);NSMutableDictionary *values=[NSMutableDictionary new];
    for(NSString *entry in strings(env,environment)){NSRange equals=[entry rangeOfString:@"="];if(equals.location!=NSNotFound)values[[entry substringToIndex:equals.location]]=[entry substringFromIndex:equals.location+1];}
    jint descriptors[3];(*env)->GetIntArrayRegion(env,fds,0,3,descriptors);
    char output[PATH_MAX];if(descriptors[1]>=0&&fcntl(descriptors[1],F_GETPATH,output)==0)values[@"BW_ENGINE_STDOUT_PATH"]=@(output);
    values[@"BW_ENGINE_MERGE_STDERR"]=merge?@"1":@"0";
    NSString *cwd=strings(env,directory).firstObject;if(cwd)values[@"BW_ENGINE_WORKING_DIRECTORY"]=cwd;
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);__block int pid=0;
    dispatch_async(dispatch_get_main_queue(),^{
        Class coordinator=NSClassFromString(@"NativeEngineCoordinator");
        void (^completion)(int)=^(int value){pid=value;dispatch_semaphore_signal(ready);};
        ((void(*)(id,SEL,id,id,id))objc_msgSend)(coordinator,NSSelectorFromString(@"startWithArguments:environment:completion:"),arguments,values,completion);
    });
    dispatch_semaphore_wait(ready,DISPATCH_TIME_FOREVER);
    if(pid<=0){(*env)->ThrowNew(env,(*env)->FindClass(env,"java/io/IOException"),"Embedded engine process could not start; see native-engine-extension.json");return -1;}
    // Bitwig communicates over its control socket; its launcher never uses
    // Process.getOutputStream. Supply a writable null input, not a fake PID.
    jint returned[3]={descriptors[0]==-1?open("/dev/null",O_WRONLY):-1,-1,-1};
    (*env)->SetIntArrayRegion(env,fds,0,3,returned);
    fprintf(stdout,"[native engine] ProcessBuilder launched embedded pid=%d\n",pid);
    return pid;
}
static jint waitEngine(JNIEnv *env,jclass cls,jlong pid,jboolean reap){
    if(!tracked(pid))return originalWait(env,cls,pid,reap);
    [condition lock];NSMutableDictionary *process=metadataProcesses[@(pid)]?:processes[@(pid)];while(![process[@"exited"] boolValue])[condition wait];int code=[process[@"code"] intValue];[condition unlock];return code;
}
static jlong aliveEngine(JNIEnv *env,jobject object,jlong pid){
    if(!tracked(pid))return originalAlive(env,object,pid);
    [condition lock];BOOL exited=[(metadataProcesses[@(pid)]?:processes[@(pid)])[@"exited"] boolValue];[condition unlock];return exited?-1:0; // JDK: 0 means alive, unknown start time.
}
static jboolean destroyEngine(JNIEnv *env,jobject object,jlong pid,jlong start,jboolean force){
    if(!tracked(pid))return originalDestroy(env,object,pid,start,force);
    if(aliveEngine(env,object,pid)<0)return JNI_FALSE;
    return kill((pid_t)pid,force?SIGKILL:SIGTERM)==0?JNI_TRUE:JNI_FALSE;
}
BOOL BWInstallEngineProcessAdapter(JNIEnv *env){
    if(!NSClassFromString(@"NativeEngineCoordinator"))return YES;
    void *java=dlopen([[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"jre/lib/libjava.dylib"] fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
    if(!java)return NO;
    originalFork=dlsym(java,"Java_java_lang_ProcessImpl_forkAndExec");originalWait=dlsym(java,"Java_java_lang_ProcessHandleImpl_waitForProcessExit0");
    originalAlive=dlsym(java,"Java_java_lang_ProcessHandleImpl_isAlive0");originalDestroy=dlsym(java,"Java_java_lang_ProcessHandleImpl_destroy0");
    if(!originalFork||!originalWait||!originalAlive||!originalDestroy)return NO;
    jclass process=(*env)->FindClass(env,"java/lang/ProcessImpl");jclass handle=(*env)->FindClass(env,"java/lang/ProcessHandleImpl");
    JNINativeMethod fork={"forkAndExec","(I[B[B[BI[BI[B[IZ)I",(void*)launchEngine};
    JNINativeMethod methods[]={{"waitForProcessExit0","(JZ)I",(void*)waitEngine},{"isAlive0","(J)J",(void*)aliveEngine},{"destroy0","(JJZ)Z",(void*)destroyEngine}};
    return process&&handle&&(*env)->RegisterNatives(env,process,&fork,1)==JNI_OK&&(*env)->RegisterNatives(env,handle,methods,3)==JNI_OK;
}
