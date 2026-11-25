#import <UIKit/UIKit.h>
#ifdef SURGE_EDITOR
#include <clap/clap.h>
#include <dlfcn.h>

typedef BOOL (*DeliverPointer)(UIView *, CGPoint, CGPoint, NSInteger);

static uint32_t noEvents(const clap_input_events_t *list) { return 0; }
static const clap_event_header_t *noEvent(const clap_input_events_t *list, uint32_t index) { return NULL; }
static bool acceptEvent(const clap_output_events_t *list, const clap_event_header_t *event) { return true; }

static double parameter(const clap_plugin_t *plugin, const clap_plugin_params_t *params, const char *name) {
    for (uint32_t i = 0; i < params->count(plugin); i++) {
        clap_param_info_t info;
        double value;
        if (params->get_info(plugin, i, &info) && !strcmp(info.name, name) && params->get_value(plugin, info.id, &value))
            return value;
    }
    return NAN;
}

static BOOL pointer(DeliverPointer deliver, UIView *view, CGPoint point, CGPoint delta, NSInteger type) {
    if (!deliver(view, point, delta, type)) return NO;
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.04]];
    return YES;
}

bool probe_editor(const clap_plugin_t *plugin) {
    NSString *bridge = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libBitwigUIKit.dylib"];
    void *image = dlopen(bridge.fileSystemRepresentation, RTLD_NOW | RTLD_NOLOAD);
    DeliverPointer deliver = image ? (DeliverPointer)dlsym(image, "BWDeliverDetachedEditorPointer") : NULL;
    if (image) dlclose(image);
    const clap_plugin_gui_t *gui = plugin->get_extension(plugin, CLAP_EXT_GUI);
    const clap_plugin_params_t *params = plugin->get_extension(plugin, CLAP_EXT_PARAMS);
    const clap_input_events_t input = {.size = noEvents, .get = noEvent};
    const clap_output_events_t output = {.try_push = acceptEvent};
    if (!deliver || !gui || !params || !gui->is_api_supported(plugin, CLAP_WINDOW_API_COCOA, false) ||
        !gui->create(plugin, CLAP_WINDOW_API_COCOA, false)) return false;

    uint32_t width = 0, height = 0;
    if (!gui->get_size(plugin, &width, &height)) return false;
#ifdef CHOW_EDITOR
    if (width != 720 || height != 620) return false;
#else
    if (width != 913 || height != 569) return false;
#endif
    UIView *parent = [[NSClassFromString(@"NSView") alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    clap_window_t window = {.api = CLAP_WINDOW_API_COCOA, .cocoa = (__bridge void *)parent};
    if (UIApplication.sharedApplication || !gui->set_parent(plugin, &window) || !gui->show(plugin)) return false;
    UIView *editor = parent.subviews.firstObject;
    if (!editor || editor.window) return false;

#ifndef CHOW_EDITOR
    CGPoint scene = CGPointMake(26, 45);
    double initialScene = parameter(plugin, params, "Active Scene");
    if (!pointer(deliver, editor, scene, CGPointZero, 1) || !pointer(deliver, editor, scene, CGPointZero, 2)) return false;
    params->flush(plugin, &input, &output);
    double switchedScene = parameter(plugin, params, "Active Scene");
    double initialCutoff = parameter(plugin, params, "B Filter 1 Cutoff");
    if (!(switchedScene - initialScene > 0.5) || !pointer(deliver, editor, CGPointMake(371, 224), CGPointZero, 1)) return false;
    for (int step = 1; step <= 5; step++)
        if (!pointer(deliver, editor, CGPointMake(371 + 15 * step, 224), CGPointMake(15, 0), 6)) return false;
    if (!pointer(deliver, editor, CGPointMake(446, 224), CGPointZero, 2)) return false;
    params->flush(plugin, &input, &output);
    double changedCutoff = parameter(plugin, params, "B Filter 1 Cutoff");
    if (!(changedCutoff - initialCutoff > 0.05)) return false;
#endif

    width = 820;
    height = 510;
    if (!gui->can_resize(plugin) || !gui->adjust_size(plugin, &width, &height) || !gui->set_size(plugin, width, height) ||
        !CGSizeEqualToSize(editor.bounds.size, CGSizeMake(width, height))) return false;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:editor.bounds.size format:format];
    UIImage *frame = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { [editor drawRect:editor.bounds]; }];
    NSData *png = UIImagePNGRepresentation(frame);
    gui->destroy(plugin);
    if (parent.subviews.count || png.length < 10000) return false;
#ifdef CHOW_EDITOR
    fprintf(stderr, "CHOW_EDITOR_PASS resized to %ux%u, rendered %zu bytes\n", width, height, png.length);
#else
    fprintf(stderr, "SURGE_EDITOR_PASS scene %.7f→%.7f cutoff %.7f→%.7f, resized to %ux%u, rendered %zu bytes\n",
            initialScene, switchedScene, initialCutoff, changedCutoff, width, height, png.length);
#endif
    return true;
}
#endif

extern int probe_surge(const char *binary, const char *bundle);
int main(int argc,char **argv) {
    @autoreleasepool {
#ifdef CHOW_EDITOR
        NSString *bundle = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"CHOWTapeModel.clap"];
        NSString *path = [bundle stringByAppendingPathComponent:@"Contents/MacOS/CHOWTapeModel"];
#else
        NSString *bundle = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"Surge XT.clap"];
        NSString *path = [bundle stringByAppendingPathComponent:@"Contents/MacOS/Surge XT"];
#endif
        return probe_surge(path.fileSystemRepresentation,bundle.fileSystemRepresentation);
    }
}
