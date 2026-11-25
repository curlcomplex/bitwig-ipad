#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <unistd.h>

@interface NativePluginMetadataHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation NativePluginMetadataHandler
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSArray<NSString *> *arguments=((NSExtensionItem *)context.inputItems.firstObject).userInfo[@"arguments"];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *host=NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSURL *frameworks=[host URLByAppendingPathComponent:@"Frameworks"];
        NSURL *helper=[frameworks URLByAppendingPathComponent:@"BitwigPluginHost.bundle"];
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
        freopen([documents stringByAppendingPathComponent:@"plug-in-metadata.log"].fileSystemRepresentation,"w",stdout);
        dup2(fileno(stdout),fileno(stderr));
        setvbuf(stdout,NULL,_IONBF,0);
        NSURL *clap=[frameworks URLByAppendingPathComponent:@"Surge XT.clap" isDirectory:YES];
        CFBundleRef bundle=CFBundleCreate(NULL,(__bridge CFURLRef)clap);
        CFArrayRef architectures=bundle?CFBundleCopyExecutableArchitectures(bundle):NULL;
        fprintf(stdout,"Surge bundle architecture count=%ld\n",architectures?CFArrayGetCount(architectures):-1L);
        if(architectures)CFRelease(architectures);
        if(bundle)CFRelease(bundle);
        int code=1;
        NSData *data=[NSData dataWithContentsOfURL:[frameworks URLByAppendingPathComponent:@"surge-plugin-host.json"]];
        NSDictionary *info=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        uintptr_t offset=[info[@"entry"] unsignedLongLongValue];
        if (arguments.count==4 && [arguments.firstObject isEqualToString:@"metadata"] && offset) {
            void *image=dlopen(helper.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
            const struct mach_header *header=NULL;
            if(image) {
                for(uint32_t i=0;i<_dyld_image_count();i++) {
                    const char *name=_dyld_get_image_name(i);
                    if(name && [@(name) hasSuffix:@"/BitwigPluginHost.bundle"]) {
                        header=_dyld_get_image_header(i);
                        break;
                    }
                }
            } else fprintf(stderr,"Plug-in metadata helper load failed: %s\n",dlerror());
            if(header) {
                int argc=(int)arguments.count+1;
                char *argv[]={strdup(helper.fileSystemRepresentation),NULL,NULL,NULL,NULL,NULL};
                for(NSUInteger i=0;i<arguments.count;i++) argv[i+1]=strdup(arguments[i].UTF8String);
                code=((int (*)(int,char **))((uintptr_t)header+offset))(argc,argv);
                for(int i=0;i<argc;i++) free(argv[i]);
            }
        }
        NSExtensionItem *reply=[NSExtensionItem new];
        reply.userInfo=@{@"exit_code":@(code)};
        [context completeRequestReturningItems:@[reply] completionHandler:nil];
    });
}
@end
