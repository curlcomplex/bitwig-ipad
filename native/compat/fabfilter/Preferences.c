#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>

CFPropertyListRef CFPreferencesCopyValue(CFStringRef key, CFStringRef domain, CFStringRef user, CFStringRef host) {
    // The pinned desktop libraries ship macOS-only Metal resources. Select
    // FabFilter's documented software renderer without changing stored prefs.
    if (key && domain && user && host && CFEqual(key, CFSTR("GraphicsAcceleration")) &&
        CFEqual(domain, CFSTR("com.fabfilter.Common")) &&
        CFEqual(user, kCFPreferencesCurrentUser) && CFEqual(host, kCFPreferencesAnyHost)) {
        int software = 0;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &software);
    }
    static CFPropertyListRef (*copyValue)(CFStringRef, CFStringRef, CFStringRef, CFStringRef);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *foundation = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LOCAL | RTLD_LAZY);
        if (foundation) copyValue = dlsym(foundation, "CFPreferencesCopyValue");
    });
    return copyValue ? copyValue(key, domain, user, host) : NULL;
}
