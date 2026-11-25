#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <unistd.h>

extern dispatch_source_t BWStartDSPProfile(const struct mach_header *header, NSString *documents);

@interface NativeEngineHandler:NSObject <NSExtensionRequestHandling>
@property(nonatomic,strong) NSExtensionContext *context;
@property(nonatomic,strong) dispatch_source_t logCapture;
@end
@implementation NativeEngineHandler
- (void)beginRequestWithExtensionContext:(NSExtensionContext*)context {
    self.context=context;
    NSDictionary *input=((NSExtensionItem*)context.inputItems.firstObject).userInfo;
    NSArray<NSString*> *arguments=input[@"bitwig.engine.arguments"]?:@[];
    NSDictionary<NSString*,NSString*> *environment=input[@"bitwig.engine.environment"]?:@{};
    // Bitwig's engine owns an AppKit-style main run loop. Its entry point must
    // execute on this extension's main thread, as it does in the desktop process.
    dispatch_async(dispatch_get_main_queue(),^{@autoreleasepool{
        NSMutableDictionary *result=[@{@"pid":@(getpid()),@"loaded":@NO} mutableCopy];
        NSURL *host=NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSString *path=[[host URLByAppendingPathComponent:@"Frameworks/BitwigAudioEngine.bundle"] path];
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
        chdir((environment[@"BW_ENGINE_WORKING_DIRECTORY"]?:documents).fileSystemRepresentation);
        NSString *log=environment[@"BW_ENGINE_STDOUT_PATH"]?:[documents stringByAppendingPathComponent:@"engine.log"];
        NSString *errors=[documents stringByAppendingPathComponent:@"engine-errors.log"];
        freopen(log.fileSystemRepresentation,"w",stdout);freopen(errors.fileSystemRepresentation,"w",stderr);
        if([environment[@"BW_ENGINE_MERGE_STDERR"] isEqual:@"1"])dup2(fileno(stdout),fileno(stderr));
        setvbuf(stdout,NULL,_IONBF,0);setvbuf(stderr,NULL,_IONBF,0);
        // Keep a bounded diagnostic tail accessible in the extension container
        // while the real engine is running and stdout is redirected by Java.
        NSString *liveLog=[documents stringByAppendingPathComponent:@"engine-live.log"];
        self.logCapture=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
        dispatch_source_set_timer(self.logCapture,dispatch_time(DISPATCH_TIME_NOW,0),100*NSEC_PER_MSEC,10*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(self.logCapture,^{@autoreleasepool{
            NSFileHandle *reader=[NSFileHandle fileHandleForReadingAtPath:log];
            if(reader){unsigned long long end=[reader seekToEndOfFile];[reader seekToFileOffset:end>65536?end-65536:0];[[reader readDataToEndOfFile] writeToFile:liveLog atomically:YES];[reader closeFile];}
        }});
        dispatch_resume(self.logCapture);
        for(NSString *name in environment){if([name hasPrefix:@"BITWIG_"]||[name hasPrefix:@"NITRO_"])setenv(name.UTF8String,environment[name].UTF8String,1);}
        setenv("BITWIG_ENGINE_CRASH_DUMP_FILE",[[documents stringByAppendingPathComponent:@"engine-crash.txt"] fileSystemRepresentation],1);
        void *posix=dlopen([[host URLByAppendingPathComponent:@"Frameworks/libPosixBridge.dylib"] fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
        bool (*prepare)(void)=posix?dlsym(posix,"BWPrepareEngineJIT"):NULL;
        if(!prepare||!prepare()){
            fprintf(stderr,"Engine executable-memory preparation failed\n");
            [self.context cancelRequestWithError:[NSError errorWithDomain:@"BitwigEngineJIT" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Audio engine executable-memory preparation failed"}]];return;
        }
        void *image=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
        if(!image){const char *error=dlerror();result[@"error"]=error?@(error):@"Engine image did not load";}
        else {
            result[@"loaded"]=@YES;
            NSData *data=[NSData dataWithContentsOfURL:[host URLByAppendingPathComponent:@"engine-entry.json"]];
            NSDictionary *metadata=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            uintptr_t offset=[metadata[@"entry_offset"] unsignedLongLongValue];const struct mach_header *header=NULL;
            for(uint32_t i=0;i<_dyld_image_count();i++)if([@(_dyld_get_image_name(i)) hasSuffix:@"/BitwigAudioEngine.bundle"]){header=_dyld_get_image_header(i);break;}
            if(header&&offset){
                bool (*installMemory)(const void*)=dlsym(posix,"BWInstallEngineMemoryManager");
                if(!installMemory||!installMemory(header)){
                    [self.context cancelRequestWithError:[NSError errorWithDomain:@"BitwigEngineJIT" code:2 userInfo:@{NSLocalizedDescriptionKey:@"LLVM code memory adaptation failed; see engine-jit-state.json"}]];return;
                }
                dispatch_source_t profile = nil;
                if ([input[@"bitwig.engine.profile"] boolValue]) {
                    setenv("BW_DSP_PROFILE", "1", 1);
                    profile = BWStartDSPProfile(header, documents);
                }
                int argc=(int)arguments.count+1;char **argv=calloc(argc+1,sizeof(char*));argv[0]=strdup(path.fileSystemRepresentation);
                for(NSUInteger i=0;i<arguments.count;i++)argv[i+1]=strdup(arguments[i].UTF8String);
                fprintf(stdout,"Starting original Bitwig engine in embedded process %d\n",getpid());
                result[@"exit_code"]=@(((int(*)(int,char**))((uintptr_t)header+offset))(argc,argv));
                if (profile) dispatch_source_cancel(profile);
                for(int i=0;i<argc;i++)free(argv[i]);free(argv);
            } else result[@"error"]=@"Missing engine entry metadata";
        }
        for(NSArray *pair in @[@[@"stdout",log],@[@"stderr",errors]]){
            NSString *text=[NSString stringWithContentsOfFile:pair[1] encoding:NSUTF8StringEncoding error:nil]?:@"";
            result[pair[0]]=text.length>65536?[text substringFromIndex:text.length-65536]:text;
        }
        NSExtensionItem *reply=[NSExtensionItem new];reply.userInfo=@{@"bitwig.engine.result":result};
        dispatch_source_cancel(self.logCapture);self.logCapture=nil;
        [self.context completeRequestReturningItems:@[reply] completionHandler:nil];
    }});
}
@end
