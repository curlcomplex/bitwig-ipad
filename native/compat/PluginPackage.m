#import "PluginPackage.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <sys/stat.h>

static NSString *BWSHA256(NSData *data) {
    if (!data || data.length > UINT32_MAX) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hash=[NSMutableString new];
    for (NSUInteger i=0;i<sizeof(digest);i++) [hash appendFormat:@"%02x",digest[i]];
    return hash;
}

static NSURL *BWPackageManifest(NSURL *folder) {
    return [folder URLByAppendingPathComponent:@"Package.plist"];
}

static NSString *BWStagePlugin(NSURL *source, NSString **nameResult, NSURL **generationResult) {
    NSFileManager *files=NSFileManager.defaultManager;
    NSURL *root=BWPreparedPluginRoot();
    if (!root || ![files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil])
        return @"The shared plug-in directory is unavailable.";
    NSURL *generation=[root URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    struct stat sourceState={};
    if (lstat(source.fileSystemRepresentation,&sourceState)!=0 || !S_ISDIR(sourceState.st_mode))
        return @"Choose a regular prepared folder.";
    BOOL valid=NO;
    @try {
        NSError *copyError=nil;
        if (![files copyItemAtURL:source toURL:generation error:&copyError])
            return copyError.localizedDescription ?: @"Bitwig could not copy the prepared folder.";
        struct stat entry={};
        if (lstat(generation.fileSystemRepresentation,&entry)!=0 || !S_ISDIR(entry.st_mode))
            return @"Choose a regular prepared folder.";
        NSURL *manifestURL=BWPackageManifest(generation);
        if (lstat(manifestURL.fileSystemRepresentation,&entry)!=0 || !S_ISREG(entry.st_mode) || entry.st_size>1048576)
            return @"Choose a folder created by the Mac plug-in preparer.";
        NSDictionary *manifest=[NSDictionary dictionaryWithContentsOfURL:manifestURL];
        NSString *name=manifest[@"bundle"];
        if (![name isKindOfClass:NSString.class] || !BWPreparedPluginImageName(name) ||
            ![manifest[@"image"] isEqual:BWPreparedPluginImageName(name)] || ![manifest[@"bridgeABI"] isEqual:@1] ||
            ![manifest[@"files"] isKindOfClass:NSDictionary.class])
            return @"This plug-in package requires a matching host and preparation recipe.";
        NSDictionary *hashes=manifest[@"files"];
        NSString *info=[name stringByAppendingPathComponent:@"Contents/Info.plist"];
        if (!hashes[manifest[@"image"]] || !hashes[info])
            return @"The prepared executable or bundle information is missing.";
        NSString *contentsPrefix=[name stringByAppendingString:@"/Contents/"];
        NSMutableSet *seen=[NSMutableSet new];
        NSDirectoryEnumerator *tree=[files enumeratorAtURL:generation includingPropertiesForKeys:nil options:0 errorHandler:nil];
        for (NSURL *file in tree) {
            if (lstat(file.fileSystemRepresentation,&entry)!=0 || S_ISLNK(entry.st_mode))
                return @"Prepared folders must contain their own files.";
            if (S_ISDIR(entry.st_mode)) continue;
            NSString *relative=[file.path substringFromIndex:generation.path.length+1];
            if ([relative isEqualToString:@"Package.plist"]) continue;
            if ([file.lastPathComponent isEqualToString:@".DS_Store"] || [file.lastPathComponent hasPrefix:@"._"]) {
                [files removeItemAtURL:file error:nil];
                continue;
            }
            if (![relative isEqualToString:manifest[@"image"]] && ![relative hasPrefix:contentsPrefix])
                return @"The package contains a file outside its prepared bundle.";
            if (!S_ISREG(entry.st_mode) || entry.st_size>UINT32_MAX ||
                ![BWSHA256([NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil]) isEqual:hashes[relative]])
                return @"A prepared file is missing, changed, or unsupported.";
            [seen addObject:relative];
        }
        if (seen.count!=hashes.count) return @"The prepared folder is incomplete.";
        NSDictionary *recipeTable=[NSBundle.mainBundle objectForInfoDictionaryKey:@"BWPreparedPluginRecipes"];
        NSArray *recipe=recipeTable[name];
        NSDictionary *bundleInfo=[NSDictionary dictionaryWithContentsOfURL:[generation URLByAppendingPathComponent:info]];
        if (recipe.count != 2 || ![bundleInfo[@"CFBundleIdentifier"] isEqual:recipe[0]] ||
            ![bundleInfo[@"CFBundleShortVersionString"] isEqual:recipe[1]])
            return @"The plug-in does not match this host's preparation recipe.";
        NSURL *imageURL=[generation URLByAppendingPathComponent:manifest[@"image"]];
        NSFileHandle *image=[NSFileHandle fileHandleForReadingFromURL:imageURL error:nil];
        NSData *headerData=[image readDataOfLength:sizeof(struct mach_header_64)];
        [image closeFile];
        struct mach_header_64 header={};
        if (headerData.length==sizeof(header)) [headerData getBytes:&header length:sizeof(header)];
        if (header.magic!=MH_MAGIC_64 || header.cputype!=CPU_TYPE_ARM64 || header.filetype!=MH_BUNDLE)
            return @"The prepared executable is not an ARM64 plug-in bundle.";
        valid=YES;
        *nameResult=name;
        *generationResult=generation;
        return nil;
    } @finally {
        if (!valid) [files removeItemAtURL:generation error:nil];
    }
}

static NSString *BWInstallPluginFolders(NSArray<NSURL *> *folders,NSUInteger *count) {
    NSFileManager *files=NSFileManager.defaultManager;
    NSMutableDictionary *installed=[BWReadPreparedPluginRegistry() mutableCopy];
    NSMutableDictionary<NSString *,NSURL *> *staged=[NSMutableDictionary new];
    NSString *failure=nil;
    for (NSURL *source in folders) {
        BOOL access=[source startAccessingSecurityScopedResource];
        @try {
            NSArray<NSURL *> *packages=@[source];
            if (![files fileExistsAtPath:BWPackageManifest(source).path]) {
                packages=[files contentsOfDirectoryAtURL:source includingPropertiesForKeys:nil
                                                options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
            }
            if (!packages.count) {
                failure=@"Choose a prepared plug-in folder or a folder of prepared plug-ins.";
                break;
            }
            for (NSURL *package in packages) {
                NSString *name=nil;
                NSURL *generation=nil;
                failure=BWStagePlugin(package,&name,&generation);
                if (failure) break;
                if (staged[name]) {
                    [files removeItemAtURL:generation error:nil];
                    failure=@"The selection contains the same plug-in twice.";
                    break;
                }
                staged[name]=generation;
                installed[name]=generation.lastPathComponent;
            }
        } @finally {
            if (access) [source stopAccessingSecurityScopedResource];
        }
        if (failure) break;
    }
    if (!failure && ![installed writeToURL:BWPreparedPluginRegistry() error:nil])
        failure=@"Bitwig could not save the installed plug-ins.";
    if (failure) {
        for (NSURL *generation in staged.allValues) [files removeItemAtURL:generation error:nil];
    } else *count=staged.count;
    return failure;
}

@interface BWPluginPicker : NSObject <UIDocumentPickerDelegate>
@property(nonatomic,weak) UIViewController *presenter;
@end

static BWPluginPicker *activePicker;
static dispatch_queue_t BWPluginImportQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("org.bitwigipad.plugin-import",DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static void BWPluginNotice(UIViewController *presenter,NSString *title,NSString *detail) {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@implementation BWPluginPicker
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { activePicker=nil; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    UIViewController *presenter=self.presenter;
    activePicker=nil;
    if (!urls.count) return;
    dispatch_async(BWPluginImportQueue(), ^{
        NSUInteger count=0;
        NSString *error=BWInstallPluginFolders(urls,&count);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *title=error ? @"Plug-ins not installed" : [NSString stringWithFormat:@"%lu installed",(unsigned long)count];
            BWPluginNotice(presenter,title,error ?: @"Quit and reopen Bitwig to load the plug-ins.");
        });
    });
}
@end

static void BWPresentPluginPicker(UIViewController *presenter) {
    activePicker=[BWPluginPicker new];
    activePicker.presenter=presenter;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate=activePicker;
    picker.allowsMultipleSelection=YES;
    [presenter presentViewController:picker animated:YES completion:nil];
}

static void BWRemovePreparedPlugin(UIViewController *presenter, NSString *name) {
    dispatch_async(BWPluginImportQueue(), ^{
        NSMutableDictionary *installed=[BWReadPreparedPluginRegistry() mutableCopy];
        [installed removeObjectForKey:name];
        NSError *error=nil;
        BOOL saved=[installed writeToURL:BWPreparedPluginRegistry() error:&error];
        NSString *detail=error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{
            BWPluginNotice(presenter,saved ? @"Plug-in removed" : @"Could not remove plug-in",
                           detail ?: @"Quit and reopen Bitwig to refresh the browser. Saved projects keep their plug-in state.");
        });
    });
}

void BWShowPreparedPlugins(void) {
    if (!BWIndependentPluginsEnabled()) return;
    UIViewController *presenter=nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState!=UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (window.isKeyWindow) { presenter=window.rootViewController; break; }
        if (presenter) break;
    }
    while (presenter.presentedViewController) presenter=presenter.presentedViewController;
    if (!presenter || activePicker) return;
    UIAlertController *manager=[UIAlertController alertControllerWithTitle:@"Plug-ins" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [manager addAction:[UIAlertAction actionWithTitle:@"Import Prepared Folder…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        BWPresentPluginPicker(presenter);
    }]];
    for (NSString *name in [BWReadPreparedPluginRegistry().allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if (!BWPreparedPluginImageName(name)) continue;
        [manager addAction:[UIAlertAction actionWithTitle:[@"Remove " stringByAppendingString:name] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"Remove Plug-in?" message:name preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *remove) {
                BWRemovePreparedPlugin(presenter,name);
            }]];
            [presenter presentViewController:confirm animated:YES completion:nil];
        }]];
    }
    [manager addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:manager animated:YES completion:nil];
}

void BWInstallPluginButton(UIView *view) {
    if (!BWIndependentPluginsEnabled()) return;
    UIView *existing=[view viewWithTag:38127];
    if (existing) {
        if (view.subviews.lastObject!=existing) [view bringSubviewToFront:existing];
        return;
    }
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    button.tag=38127;
    button.translatesAutoresizingMaskIntoConstraints=NO;
    button.accessibilityLabel=@"Manage Plug-ins";
    [button setImage:[UIImage systemImageNamed:@"puzzlepiece.extension"] forState:UIControlStateNormal];
    button.tintColor=UIColor.whiteColor;
    [button addAction:[UIAction actionWithHandler:^(UIAction *action) {
        BWShowPreparedPlugins();
    }] forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:view.topAnchor],
        [button.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-35],
        [button.widthAnchor constraintEqualToConstant:44],
        [button.heightAnchor constraintEqualToConstant:27],
    ]];
}
