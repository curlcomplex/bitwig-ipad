#pragma once
#import <Foundation/Foundation.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static inline BOOL BWCompatibilityTracing(void) {
    static dispatch_once_t once;
    static BOOL enabled;
    dispatch_once(&once, ^{
        enabled = [NSProcessInfo.processInfo.arguments containsObject:@"--native-compat-trace"];
    });
    return enabled;
}

static inline void BWCompatibilityTrace(const char *operation, const char *owner,
                                        const char *name, const char *outcome) {
    int savedErrno = errno;
    if (BWCompatibilityTracing()) {
        const char *source = strrchr(__BASE_FILE__, '/');
        source = source ? source + 1 : __BASE_FILE__;
        static _Atomic unsigned records;
        unsigned index = atomic_fetch_add_explicit(&records, 1, memory_order_relaxed);
        if (index < 128) {
            fprintf(stderr, "[compat-boundary] %s %s %s %s %s\n", source, operation, owner, name, outcome);
        } else if (index == 128) {
            fprintf(stderr, "[compat-boundary] %s recorded=128 dropped>=1\n", source);
        }
    }
    errno = savedErrno;
}
