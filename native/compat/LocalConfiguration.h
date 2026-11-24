#pragma once
#import <Foundation/Foundation.h>

static inline NSURL *BWSharedContainerURL(void) {
    NSString *group = [NSBundle.mainBundle objectForInfoDictionaryKey:@"BWAppGroupIdentifier"];
    return group.length ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
}

static inline NSString *BWIPCGroupIdentifier(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"BWIPCGroupIdentifier"];
}
