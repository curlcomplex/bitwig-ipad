#pragma once
#import "LocalConfiguration.h"

static inline BOOL BWIndependentPluginsEnabled(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    if ([bundle.bundleURL.pathExtension isEqualToString:@"appex"])
        bundle = [NSBundle bundleWithURL:bundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
    return [[bundle objectForInfoDictionaryKey:@"BWIndependentPlugins"] boolValue];
}

static inline NSURL *BWPreparedPluginRoot(void) {
    return [BWSharedContainerURL() URLByAppendingPathComponent:@"Prepared Plug-ins" isDirectory:YES];
}

static inline NSURL *BWPreparedPluginRegistry(void) {
    return [BWPreparedPluginRoot() URLByAppendingPathComponent:@"Installed.plist"];
}

static inline NSDictionary *BWReadPreparedPluginRegistry(void) {
    return [NSDictionary dictionaryWithContentsOfURL:BWPreparedPluginRegistry()] ?: @{};
}

static inline NSString *BWPreparedPluginImageName(NSString *name) {
    if ([name isEqualToString:@"Surge XT.clap"]) return @"SurgeXT.bundle";
    if ([name isEqualToString:@"CHOWTapeModel.clap"]) return @"CHOWTapeModel.bundle";
    if ([name isEqualToString:@"OTT.vst3"]) return @"OTT.bundle";
    if ([name isEqualToString:@"NeuralAmpModeler.vst3"]) return @"NeuralAmpModeler.bundle";
    NSArray *fabfilter = @[@"Micro", @"One", @"Pro-C 2", @"Pro-DS", @"Pro-G", @"Pro-L 2", @"Pro-L",
        @"Pro-MB", @"Pro-Q 2", @"Pro-Q 3", @"Pro-Q 4", @"Pro-R 2", @"Pro-R", @"Saturn 2", @"Saturn",
        @"Simplon", @"Timeless 2", @"Timeless 3", @"Twin 2", @"Twin 3", @"Volcano 2", @"Volcano 3"];
    NSString *stem = name.stringByDeletingPathExtension;
    if ([name.pathExtension isEqualToString:@"clap"] && [stem hasPrefix:@"FabFilter "] &&
        [fabfilter containsObject:[stem substringFromIndex:10]]) {
        stem = [[stem stringByReplacingOccurrencesOfString:@" " withString:@""] stringByReplacingOccurrencesOfString:@"-" withString:@""];
        return [stem stringByAppendingPathExtension:@"bundle"];
    }
    return nil;
}

static inline NSURL *BWPreparedPluginDirectory(NSURL *bundle) {
    NSString *name=bundle.lastPathComponent;
    if (!BWPreparedPluginImageName(name)) return nil;
    NSURL *format=[BWManagedPluginRoot() URLByAppendingPathComponent:name.pathExtension.uppercaseString isDirectory:YES];
    NSURL *expected=[format URLByAppendingPathComponent:name isDirectory:YES];
    if (![bundle.URLByStandardizingPath.path isEqualToString:expected.URLByStandardizingPath.path]) return nil;
    NSURL *contents=[bundle URLByAppendingPathComponent:@"Contents" isDirectory:YES].URLByResolvingSymlinksInPath;
    NSURL *owner=contents.URLByDeletingLastPathComponent;
    NSURL *generation=owner.URLByDeletingLastPathComponent;
    if (![contents.lastPathComponent isEqualToString:@"Contents"] || ![owner.lastPathComponent isEqualToString:name] ||
        ![[NSUUID alloc] initWithUUIDString:generation.lastPathComponent] ||
        ![generation.URLByDeletingLastPathComponent.path isEqualToString:BWPreparedPluginRoot().URLByResolvingSymlinksInPath.path])
        return nil;
    return generation;
}
