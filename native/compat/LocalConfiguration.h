#pragma once
#import <Foundation/Foundation.h>

static inline NSURL *BWSharedContainerURL(void) {
    NSString *group = [NSBundle.mainBundle objectForInfoDictionaryKey:@"BWAppGroupIdentifier"];
    return group.length ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
}

static inline NSString *BWIPCGroupIdentifier(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"BWIPCGroupIdentifier"];
}

static inline NSURL *BWManagedPluginRoot(void) {
    return [BWSharedContainerURL() URLByAppendingPathComponent:@"Managed Plug-ins" isDirectory:YES];
}
