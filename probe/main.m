#import <UIKit/UIKit.h>
extern int run_henge_probe(void);
@interface ProbeScene : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow *window;
@end
@implementation ProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *text = [[UITextView alloc] initWithFrame:vc.view.bounds];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
    text.text = @"Henge simulator core probe\nRunning upstream ARM64 translation checks…";
    [vc.view addSubview:text];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [documents stringByAppendingPathComponent:@"probe.log"];
        freopen(path.fileSystemRepresentation, "w", stdout);
        setvbuf(stdout, NULL, _IONBF, 0);
        int result = run_henge_probe();
        printf("RESULT=%d\n", result);
        fflush(stdout);
        NSString *log = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        [@{ @"exit_code": @(result), @"scope": @"Simulator translation core only; no macOS boot or Bitwig execution" } writeToFile:[documents stringByAppendingPathComponent:@"result.plist"] atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ text.text = [@"Henge simulator core probe\n\n" stringByAppendingString:log ?: @"No log"]; });
    }];
    // Upstream's native comparison keeps two large HvCpu snapshots on its stack.
    worker.stackSize = 16 * 1024 * 1024;
    [worker start];
}
@end
@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Probe" sessionRole:session.role];
    configuration.delegateClass = ProbeScene.class;
    return configuration;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeDelegate.class)); }
}
