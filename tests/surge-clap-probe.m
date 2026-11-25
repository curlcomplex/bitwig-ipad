#import <UIKit/UIKit.h>
extern int probe_surge(const char *binary, const char *bundle);
int main(int argc,char **argv) {
    @autoreleasepool {
        NSString *bundle=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/Surge XT.clap"];
        NSString *path=[bundle stringByAppendingPathComponent:@"Contents/MacOS/Surge XT"];
        return probe_surge(path.fileSystemRepresentation,bundle.fileSystemRepresentation);
    }
}
