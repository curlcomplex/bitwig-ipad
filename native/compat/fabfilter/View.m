#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <string.h>

BOOL BWIsFabFilterEditorView(UIView *view) {
    static const char prefix[] = "ComFabFilter_";
    static const char suffix[] = "_CLAP_InterfaceView";
    static const char products[][5] = {
        "FMic", "FOne", "FC2p", "FPSr", "FPGr", "FL2p", "FPLr", "FPMb", "FQ2p", "FQ3p", "FQ4p",
        "FR2p", "FPRr", "FS2a", "FSat", "FSim", "FTms", "F3Ts", "FT2i", "FT3i", "FV2l", "FV3l",
    };
    if (!view) return NO;
    const char *name = object_getClassName(view);
    size_t head = sizeof(prefix) - 1, tail = sizeof(suffix) - 1;
    if (strlen(name) != head + 4 + tail || strncmp(name, prefix, head) ||
        strcmp(name + head + 4, suffix)) return NO;
    for (size_t i = 0; i < sizeof(products) / sizeof(products[0]); i++)
        if (!strncmp(name + head, products[i], 4)) return YES;
    return NO;
}
