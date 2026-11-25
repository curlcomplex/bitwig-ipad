#include <clap/clap.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdatomic.h>
#include <string.h>

#if BW_SURGE_REMOTE
#import <UIKit/UIKit.h>
#import "../LocalConfiguration.h"
extern id BWPublishDetachedEditor(UIView *parent, dispatch_block_t close);
extern void BWStopPublishingDetachedEditor(id publisher);

@interface BWRemoteEditor : NSObject
@property(nonatomic) const clap_host_t *host;
@property(nonatomic, strong) UIView *parent;
@property(nonatomic, strong) id publisher;
@property(nonatomic) BOOL created;
@property(nonatomic) BOOL floating;
@end
@implementation BWRemoteEditor
@end

static NSMutableDictionary<NSValue *, BWRemoteEditor *> *instances;
static BOOL usesRemoteEditor(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *extension = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSExtension"];
        BOOL engine = [extension[@"NSExtensionPrincipalClass"] isEqualToString:@"NativeEngineHandler"];
        BOOL shared = BWSharedContainerURL() != nil;
        enabled = engine && shared;
        fprintf(stderr, "Surge editor route engine=%d shared=%d remote=%d\n", engine, shared, enabled);
    });
    return enabled;
}

static BWRemoteEditor *instance(const clap_plugin_t *plugin) {
    if (!usesRemoteEditor()) return nil;
    @synchronized (BWRemoteEditor.class) { return instances[[NSValue valueWithPointer:plugin]]; }
}

static void editorFailure(NSString *phase, NSException *exception) {
    NSString *reason = [NSString stringWithFormat:@"Surge editor %@: %@: %@", phase, exception.name, exception.reason];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *path = [documents URLByAppendingPathComponent:@"surge-editor-failure.log"];
    [reason writeToURL:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"%@", reason);
}
#endif

// The loader uses this only for the exact staged Surge binary. Preserve the
// vendor instance address because both original callbacks and other CLAP
// extension tables consume that address directly.
typedef const void *(CLAP_ABI *GetExtension)(const clap_plugin_t *, const char *);
static _Atomic(GetExtension) originalExtension;
#if BW_SURGE_REMOTE
typedef void (CLAP_ABI *DestroyPlugin)(const clap_plugin_t *);
static _Atomic(DestroyPlugin) originalDestroy;
#endif
static const clap_plugin_entry_t *originalEntry;
static _Atomic(const clap_plugin_factory_t *) originalFactory;
static clap_plugin_entry_t wrappedEntry;

static bool writable(const void *address, size_t length) {
    vm_address_t start = (vm_address_t)address;
    vm_address_t region = start;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
                                       (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    return result == KERN_SUCCESS && (info.protection & VM_PROT_WRITE) && region <= start &&
           length <= size && start - region <= size - length;
}

static const clap_plugin_gui_t *guiFor(const clap_plugin_t *plugin) {
    return atomic_load(&originalExtension)(plugin, CLAP_EXT_GUI);
}

static bool CLAP_ABI supported(const clap_plugin_t *plugin, const char *api, bool floating) {
#if BW_SURGE_REMOTE
    if (instance(plugin) && (!api || !*api || !strcmp(api, CLAP_WINDOW_API_COCOA)))
        return guiFor(plugin)->is_api_supported(plugin, CLAP_WINDOW_API_COCOA, false);
#endif
    bool result = guiFor(plugin)->is_api_supported(plugin, api, floating);
    fprintf(stderr, "Surge editor supports %s floating=%d: %d\n", api ?: "(default)", floating, result);
    return result;
}

static bool CLAP_ABI createEditor(const clap_plugin_t *plugin, const char *api, bool floating) {
    fprintf(stderr, "Surge editor create %s floating=%d\n", api ?: "(default)", floating);
#if BW_SURGE_REMOTE
    BWRemoteEditor *editor = instance(plugin);
    @try {
        bool result;
        if (editor && (!api || !*api || !strcmp(api, CLAP_WINDOW_API_COCOA))) {
            if (editor.created) return false;
            editor.floating = floating;
            editor.created = guiFor(plugin)->create(plugin, CLAP_WINDOW_API_COCOA, false);
            result = editor.created;
        } else {
            result = guiFor(plugin)->create(plugin, api, floating);
        }
        fprintf(stderr, "Surge editor create returned %d remoteInstance=%d\n", result, editor != nil);
        return result;
    } @catch (NSException *exception) { editorFailure(@"create", exception); @throw; }
#else
    return guiFor(plugin)->create(plugin, api, floating);
#endif
}

#if BW_SURGE_REMOTE
static bool attach(const clap_plugin_t *plugin, BWRemoteEditor *editor) {
    if (editor.parent) return true;
    uint32_t width = 0, height = 0;
    const clap_plugin_gui_t *gui = guiFor(plugin);
    if (!gui->get_size(plugin, &width, &height) || !width || !height) return false;
    UIView *parent = [[NSClassFromString(@"NSView") alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    clap_window_t window = {.api = CLAP_WINDOW_API_COCOA, .cocoa = (__bridge void *)parent};
    if (!parent || !gui->set_parent(plugin, &window)) return false;
    editor.parent = parent;
    return true;
}

static bool CLAP_ABI setParent(const clap_plugin_t *plugin, const clap_window_t *window) {
    BWRemoteEditor *editor = instance(plugin);
    @try {
        bool result = editor ? (editor.created && window && window->api && !strcmp(window->api, CLAP_WINDOW_API_COCOA) && attach(plugin, editor)) :
                               guiFor(plugin)->set_parent(plugin, window);
        fprintf(stderr, "Surge editor attach returned %d remoteInstance=%d\n", result, editor != nil);
        return result;
    } @catch (NSException *exception) { editorFailure(@"attach", exception); @throw; }
}

static bool CLAP_ABI setTransient(const clap_plugin_t *plugin, const clap_window_t *window) {
    BWRemoteEditor *editor = instance(plugin);
    if (!editor) return guiFor(plugin)->set_transient(plugin, window);
    return editor.created && editor.floating && window && window->api && !strcmp(window->api, CLAP_WINDOW_API_COCOA);
}

static bool CLAP_ABI setSize(const clap_plugin_t *plugin, uint32_t width, uint32_t height) {
    const clap_plugin_gui_t *gui = guiFor(plugin);
    if (!gui->set_size(plugin, width, height)) return false;
    BWRemoteEditor *editor = instance(plugin);
    if (editor.parent && gui->get_size(plugin, &width, &height) && width && height) {
        editor.parent.frame = CGRectMake(0, 0, width, height);
    }
    return true;
}

static bool CLAP_ABI hideEditor(const clap_plugin_t *plugin) {
    BWRemoteEditor *editor = instance(plugin);
    if (!editor) return guiFor(plugin)->hide(plugin);
    if (!editor.created) return false;
    BWStopPublishingDetachedEditor(editor.publisher);
    editor.publisher = nil;
    guiFor(plugin)->hide(plugin);
    return true;
}

static bool CLAP_ABI showEditor(const clap_plugin_t *plugin) {
    BWRemoteEditor *editor = instance(plugin);
    const clap_plugin_gui_t *gui = guiFor(plugin);
    @try {
        if (!editor) return gui->show(plugin);
        if (!editor.created || !attach(plugin, editor)) return false;
        if (editor.publisher) return true;
        if (!gui->show(plugin)) return false;
    } @catch (NSException *exception) { editorFailure(@"show", exception); @throw; }
    __weak BWRemoteEditor *weakEditor = editor;
    editor.publisher = BWPublishDetachedEditor(editor.parent, ^{
        BWRemoteEditor *current = weakEditor;
        if (!current) return;
        hideEditor(plugin);
        const clap_host_gui_t *hostGUI = current.host->get_extension(current.host, CLAP_EXT_GUI);
        if (current.floating && hostGUI && hostGUI->closed) hostGUI->closed(current.host, false);
        else if (hostGUI && hostGUI->request_hide) hostGUI->request_hide(current.host);
    });
    if (!editor.publisher) gui->hide(plugin);
    fprintf(stderr, "Surge editor publication returned %d\n", editor.publisher != nil);
    return editor.publisher != nil;
}

static void CLAP_ABI destroyEditor(const clap_plugin_t *plugin) {
    BWRemoteEditor *editor = instance(plugin);
    if (!editor) { guiFor(plugin)->destroy(plugin); return; }
    if (!editor.created) return;
    hideEditor(plugin);
    guiFor(plugin)->destroy(plugin);
    editor.parent = nil;
    editor.created = NO;
}

static void CLAP_ABI destroyPlugin(const clap_plugin_t *plugin) {
    BWRemoteEditor *editor = instance(plugin);
    if (editor.created) destroyEditor(plugin);
    @synchronized (BWRemoteEditor.class) { [instances removeObjectForKey:[NSValue valueWithPointer:plugin]]; }
    atomic_load(&originalDestroy)(plugin);
}
#endif

static const void *CLAP_ABI extension(const clap_plugin_t *plugin, const char *id) {
    const void *original = atomic_load(&originalExtension)(plugin, id);
    if (!original || strcmp(id, CLAP_EXT_GUI)) return original;

    // Calls on this path are main-thread only. Copy the original table once
    // from the verified image and replace only the observed entry points.
    static clap_plugin_gui_t gui;
    static _Atomic unsigned int ready;
    unsigned int idle = 0;
    if (atomic_compare_exchange_strong(&ready, &idle, 1)) {
        gui = *(const clap_plugin_gui_t *)original;
        gui.is_api_supported = supported;
        gui.create = createEditor;
#if BW_SURGE_REMOTE
        gui.set_parent = setParent;
        gui.set_size = setSize;
        gui.set_transient = setTransient;
        gui.show = showEditor;
        gui.hide = hideEditor;
        gui.destroy = destroyEditor;
#endif
        atomic_store(&ready, 2);
    }
    return atomic_load(&ready) == 2 ? &gui : original;
}

static uint32_t CLAP_ABI pluginCount(const clap_plugin_factory_t *factory) {
    const clap_plugin_factory_t *original = atomic_load(&originalFactory);
    return original->get_plugin_count(original);
}

static const clap_plugin_descriptor_t *CLAP_ABI descriptor(const clap_plugin_factory_t *factory, uint32_t index) {
    const clap_plugin_factory_t *original = atomic_load(&originalFactory);
    return original->get_plugin_descriptor(original, index);
}

static const clap_plugin_t *CLAP_ABI createPlugin(const clap_plugin_factory_t *factory,
                                                   const clap_host_t *host, const char *id) {
    const clap_plugin_factory_t *original = atomic_load(&originalFactory);
    const clap_plugin_t *plugin = original->create_plugin(original, host, id);
    if (!plugin || !plugin->get_extension) return plugin;
    if (!writable(&plugin->get_extension, sizeof(plugin->get_extension))) {
        fprintf(stderr, "Surge editor CLAP instance table is read-only\n");
        return plugin;
    }
#if BW_SURGE_REMOTE
    if (usesRemoteEditor()) {
        if (!plugin->destroy || !writable(&plugin->destroy, sizeof(plugin->destroy))) return plugin;
        DestroyPlugin expected = NULL;
        if (!atomic_compare_exchange_strong(&originalDestroy, &expected, plugin->destroy) && expected != plugin->destroy)
            return plugin;
    }
#endif
    GetExtension empty = NULL;
    if (!atomic_compare_exchange_strong(&originalExtension, &empty, plugin->get_extension) && empty != plugin->get_extension)
        return plugin;
    ((clap_plugin_t *)plugin)->get_extension = extension;
#if BW_SURGE_REMOTE
    if (usesRemoteEditor()) {
        BWRemoteEditor *editor = [BWRemoteEditor new];
        editor.host = host;
        @synchronized (BWRemoteEditor.class) {
            if (!instances) instances = [NSMutableDictionary new];
            instances[[NSValue valueWithPointer:plugin]] = editor;
        }
        ((clap_plugin_t *)plugin)->destroy = destroyPlugin;
    }
#endif
    return plugin;
}

static const void *CLAP_ABI factory(const char *id) {
    const void *value = originalEntry->get_factory(id);
    if (!value || strcmp(id, CLAP_PLUGIN_FACTORY_ID)) return value;
    static const clap_plugin_factory_t wrappedFactory = {pluginCount, descriptor, createPlugin};
    const clap_plugin_factory_t *empty = NULL;
    return atomic_compare_exchange_strong(&originalFactory, &empty, value) || value == empty ? &wrappedFactory : value;
}

const clap_plugin_entry_t *BWEditorEntry(const clap_plugin_entry_t *entry) {
    // Called by the compatibility loader before the CLAP entry reaches Bitwig.
    if (!entry || !clap_version_is_compatible(entry->clap_version)) return entry;
    if (originalEntry && originalEntry != entry) return entry;
    if (!originalEntry) {
        originalEntry = entry;
        wrappedEntry = *entry;
        wrappedEntry.get_factory = factory;
    }
    return &wrappedEntry;
}
