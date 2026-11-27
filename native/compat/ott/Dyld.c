#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

// OTT's Steinberg loader keeps the NSAddImage token opaque and passes it
// back to NSLookupSymbolInImage. Keep the dlopen handle for that scope.
void *NSAddImage(const char *path, uint32_t options) {
    return path ? dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST) : NULL;
}

void *NSLookupSymbolInImage(void *image, const char *name, uint32_t options) {
    return image && name && name[0] == '_' ? dlsym(image, name + 1) : NULL;
}

void *NSAddressOfSymbol(void *symbol) {
    return symbol;
}

static int (*systemDladdr)(const void *, Dl_info *);
static pthread_once_t loaderOnce = PTHREAD_ONCE_INIT;
static pthread_mutex_t bundlePathLock = PTHREAD_MUTEX_INITIALIZER;
static char logicalBundlePath[PATH_MAX];

static void resolveDladdr(void) {
    void *system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (system) systemDladdr = dlsym(system, "dladdr");
}

int dladdr(const void *address, Dl_info *info) {
    pthread_once(&loaderOnce, resolveDladdr);
    int found = systemDladdr ? systemDladdr(address, info) : 0;
    if (!found || !info->dli_fname) return found;

    // OTT locates its original Resources by removing the last three path
    // components from its own executable. The separately signed image sits
    // alongside the copied desktop bundle on iPadOS.
    const char *file = strrchr(info->dli_fname, '/');
    if (!file || strcmp(file, "/OTT.bundle")) return found;
    static const char suffix[] = "/OTT.vst3/Contents/MacOS/OTT";
    size_t directoryLength = (size_t)(file - info->dli_fname);
    if (directoryLength >= sizeof(logicalBundlePath) - sizeof(suffix)) return found;
    pthread_mutex_lock(&bundlePathLock);
    if (!logicalBundlePath[0]) {
        memcpy(logicalBundlePath, info->dli_fname, directoryLength);
        memcpy(logicalBundlePath + directoryLength, suffix, sizeof(suffix));
    }
    info->dli_fname = logicalBundlePath;
    pthread_mutex_unlock(&bundlePathLock);
    return found;
}
