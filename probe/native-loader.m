#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdint.h>
extern void bitwig_pcm_to_float(void*, const void*, float*, unsigned, unsigned, unsigned);

static NSDictionary *testBitwigPCM(void) {
    NSData *reference = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"mac-reference" ofType:@"bin"]];
    NSMutableData *actual = [NSMutableData new];
    unsigned counts[] = {1, 3, 4, 17, 32, 37, 64};
    for (unsigned test=0; test<7; test++) {
        unsigned count=counts[test], stride=(count+4)*2;
        int16_t input[3*68]; float output[3*64] = {0};
        for (unsigned i=0; i<3*68; i++) input[i]=(int16_t)((i*7919+test*1049)&65535);
        bitwig_pcm_to_float(NULL, input, output, 3, count, stride);
        [actual appendBytes:output length:count*3*sizeof(float)];
    }
    return @{@"routine": @"Bitwig Int16LESampleDataFormat::convertToFloat",
             @"method": @"Unchanged instructions extracted at build time and linked into signed iOS executable; no JIT",
             @"reference": @"Same routine invoked inside original installed Mac library",
             @"cases": @7, @"samples": @(actual.length/sizeof(float)),
             @"bit_exact": @([actual isEqualToData:reference])};
}

@interface NativeProbeScene : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow *window;
@end
@implementation NativeProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    UITextView *text = [[UITextView alloc] initWithFrame:vc.view.bounds];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    [vc.view addSubview:text];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    NSMutableArray *results = [NSMutableArray new];
    NSDictionary *dsp = testBitwigPCM();
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    for (NSString *name in @[@"sqlite-macos.dylib", @"sqlite-ios.dylib", @"bitwig-macos.dylib", @"bitwig-ios.dylib"]) {
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        dlerror();
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        const char *error = handle ? NULL : dlerror();
        NSMutableDictionary *entry = [@{@"library": name, @"loaded": @(handle != NULL), @"error": error ? @(error) : @""} mutableCopy];
        if (handle) {
            const char *symbol = [name hasPrefix:@"sqlite"] ? "Java_org_sqlite_core_NativeDB_libversion_1utf8" : "Java_com_bitwig_base_platform_Platform_isX64";
            entry[@"symbol"] = @(symbol);
            entry[@"symbol_resolved"] = @(dlsym(handle, symbol) != NULL);
            // No missing framework stubs and no claim that dlopen establishes application compatibility.
            // Keep successfully loaded images alive until process exit.
        }
        [results addObject:entry];
        NSDictionary *report = @{@"scope": @"Native iOS component experiment; no VM, CPU translator or JIT. One routine and dependency loading do not establish application compatibility.", @"dsp": dsp, @"results": results};
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[documents stringByAppendingPathComponent:@"native-loader.json"] atomically:YES];
        text.text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
}
@end
@interface NativeProbeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation NativeProbeDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Probe" sessionRole:session.role];
    configuration.delegateClass = NativeProbeScene.class;
    return configuration;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(NativeProbeDelegate.class)); }
}
