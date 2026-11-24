#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
@interface EngineProbeScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation EngineProbeScene
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    UIViewController *controller=[UIViewController new];controller.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(30,60,680,500)];label.numberOfLines=0;[controller.view addSubview:label];
    self.window.rootViewController=controller;[self.window makeKeyAndVisible];
    NSString *path=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"BitwigAudioEngine.bundle"];
    dlerror();void *image=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);const char *error=dlerror();
    NSDictionary *result=@{@"scope":@"Original audio engine native loader check; no engine main or audio test",@"loaded":@(image!=NULL),@"error":error?@(error):@""};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"native-engine.json"] atomically:YES];
    label.text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    NSArray *arguments=NSProcessInfo.processInfo.arguments;
    NSUInteger option=[arguments indexOfObject:@"--engine-port"];
    if(image&&option!=NSNotFound&&option+1<arguments.count){
        NSString *port=arguments[option+1];
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        freopen([[documents stringByAppendingPathComponent:@"native-engine.log"] fileSystemRepresentation],"w",stdout);
        freopen([[documents stringByAppendingPathComponent:@"native-engine-errors.log"] fileSystemRepresentation],"w",stderr);
        setvbuf(stdout,NULL,_IONBF,0);setvbuf(stderr,NULL,_IONBF,0);
        chdir(documents.fileSystemRepresentation);
        setenv("BITWIG_ENGINE_CRASH_DUMP_FILE",[[documents stringByAppendingPathComponent:@"native-engine-crash.txt"] fileSystemRepresentation],1);
        NSData *metadata=[NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"engine-entry" ofType:@"json"]];
        NSDictionary *entry=[NSJSONSerialization JSONObjectWithData:metadata options:0 error:nil];
        uintptr_t offset=[entry[@"entry_offset"] unsignedLongLongValue];
        const struct mach_header *header=NULL;
        for(uint32_t index=0;index<_dyld_image_count();index++){
            if([@(_dyld_get_image_name(index)) hasSuffix:@"/BitwigAudioEngine.bundle"]){header=_dyld_get_image_header(index);break;}
        }
        if(header&&offset){
            uintptr_t address=(uintptr_t)header+offset;
            dispatch_async(dispatch_get_main_queue(),^{
                NSDictionary *running=@{@"loaded":@YES,@"phase":@"calling original engine main",@"port":port};
                [[NSJSONSerialization dataWithJSONObject:running options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"native-engine.json"] atomically:YES];
                char *argv[]={strdup(path.fileSystemRepresentation),strdup(port.UTF8String),NULL};
                fprintf(stdout,"Entering original engine main with control port %s\n",argv[1]);
                int code=((int(*)(int,char**))address)(2,argv);
                fprintf(stdout,"Original engine main returned %d\n",code);
                NSDictionary *finished=@{@"loaded":@YES,@"phase":@"engine main returned",@"exit_code":@(code)};
                [[NSJSONSerialization dataWithJSONObject:finished options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"native-engine.json"] atomically:YES];
                free(argv[0]);free(argv[1]);
            });
        }
    }
}
@end
@interface EngineProbeApp : UIResponder <UIApplicationDelegate> @end
@implementation EngineProbeApp
- (UISceneConfiguration*)application:(UIApplication*)app configurationForConnectingSceneSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
    UISceneConfiguration *config=[[UISceneConfiguration alloc] initWithName:@"Probe" sessionRole:session.role];config.delegateClass=EngineProbeScene.class;return config;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(EngineProbeApp.class));}}
