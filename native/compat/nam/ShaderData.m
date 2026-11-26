#import "../PluginPackage.h"
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <string.h>

typedef dispatch_data_t (*CreateDispatchData)(const void *, size_t, dispatch_queue_t, dispatch_block_t)
    __attribute__((ns_returns_retained));

static CreateDispatchData systemCreateData;
static NSData *platformShader;
// SHA-256 of the embedded macOS MetalNanoVG library in the pinned NAM image.
static const unsigned char desktopShaderHash[CC_SHA256_DIGEST_LENGTH] = {
    0x3d, 0xbb, 0xe5, 0xe0, 0xd1, 0x25, 0xe5, 0x9d, 0x24, 0x40, 0x26, 0xca, 0x90, 0x84, 0x65, 0xeb,
    0x63, 0xcd, 0xc8, 0x4d, 0xe8, 0xf8, 0xe4, 0x65, 0xdf, 0x42, 0x6e, 0x27, 0x23, 0x79, 0x0e, 0x73,
};

dispatch_data_t dispatch_data_create(const void *bytes, size_t length, dispatch_queue_t queue,
                                     dispatch_block_t destructor) {
    static dispatch_once_t resolve;
    dispatch_once(&resolve, ^{
        void *system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_LOCAL);
        if (system) systemCreateData = dlsym(system, "dispatch_data_create");
    });
    if (!systemCreateData) return nil;

    if (bytes && length == 12835 && destructor == DISPATCH_DATA_DESTRUCTOR_DEFAULT &&
        !memcmp(bytes, "MTLB", 4)) {
        unsigned char hash[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes, (CC_LONG)length, hash);
        if (!memcmp(hash, desktopShaderHash, sizeof(hash))) {
            void *returnAddress = __builtin_return_address(0);
            static dispatch_once_t load;
            dispatch_once(&load, ^{
                NSURL *app = NSBundle.mainBundle.bundleURL;
                if ([app.pathExtension isEqualToString:@"appex"])
                    app = app.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
                NSURL *url;
                if (BWIndependentPluginsEnabled()) {
                    Dl_info caller={};
                    if (dladdr(returnAddress, &caller) && caller.dli_fname) {
                        NSURL *image=[NSURL fileURLWithFileSystemRepresentation:caller.dli_fname isDirectory:NO relativeToURL:nil];
                        if ([image.lastPathComponent isEqualToString:@"NeuralAmpModeler.bundle"])
                            url=[image.URLByDeletingLastPathComponent URLByAppendingPathComponent:
                                @"NeuralAmpModeler.vst3/Contents/Resources/NeuralAmpModeler-iOS.metallib"];
                    }
                } else {
                    url=[app URLByAppendingPathComponent:
                        @"Frameworks/NeuralAmpModeler.vst3/Contents/Resources/NeuralAmpModeler-iOS.metallib"];
                }
                if (url) platformShader = [NSData dataWithContentsOfURL:url];
            });
            if (platformShader.length)
                return systemCreateData(platformShader.bytes, platformShader.length, queue, destructor);
        }
    }
    return systemCreateData(bytes, length, queue, destructor);
}
