#import <UIKit/UIKit.h>
#include <sys/stat.h>
#include <time.h>

extern int32_t BWStoreFSRef(NSString *, void *);
extern NSString *BWPathForFSRef(const void *);

typedef struct { uint8_t bytes[80]; } BWFSRef;
typedef struct { uint16_t length; UniChar units[255]; } BWHFSName;

// The original directory reader requests only node flags and content time.
// Preserve the other bytes and stride of the legacy 64-bit macOS record.
typedef struct __attribute__((packed, aligned(2))) {
    uint16_t flags;
    uint8_t beforeModification[22];
    uint16_t highSeconds;
    uint32_t lowSeconds;
    uint16_t fraction;
    uint8_t afterModification[116];
} BWCatalogInfo;
_Static_assert(sizeof(BWCatalogInfo) == 148, "desktop FSCatalogInfo size");

static const uint32_t BWCatalogFields = 0x42;
static int16_t fileError(int code) {
    if (code == ENOENT || code == ENOTDIR) return -43;
    if (code == EEXIST) return -48;
    return -54;
}

int32_t FSPathMakeRef(const unsigned char *path, BWFSRef *ref, unsigned char *isDirectory) {
    if (!path || !ref) return -50;
    struct stat attributes;
    if (stat((const char *)path, &attributes) != 0) return fileError(errno);
    if (isDirectory) *isDirectory = S_ISDIR(attributes.st_mode);
    NSString *string = [NSFileManager.defaultManager stringWithFileSystemRepresentation:(const char *)path
                                                                                 length:strlen((const char *)path)];
    return BWStoreFSRef(string, ref);
}

int16_t FSCreateDirectoryUnicode(const BWFSRef *parent, unsigned long length, const UniChar *name,
                                  uint32_t fields, const void *catalog, BWFSRef *created, void *spec,
                                  uint32_t *directoryID) {
    if (fields || catalog || spec || directoryID || !name || !length || length > 255) return -50;
    NSString *directory = BWPathForFSRef(parent);
    if (!directory) return -1401;
    NSString *component = [NSString stringWithCharacters:name length:length];
    if ([component containsString:@"/"] || [component isEqualToString:@"."] ||
        [component isEqualToString:@".."] || [component rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
        return -50;
    NSString *path = [directory stringByAppendingPathComponent:component];
    if (mkdir(path.fileSystemRepresentation, 0777) != 0) return fileError(errno);
    return created ? BWStoreFSRef(path, created) : 0;
}

@interface BWFabFilterDirectory : NSObject
@property(nonatomic, strong) NSDirectoryEnumerator<NSURL *> *items;
@end
@implementation BWFabFilterDirectory
@end

int16_t FSOpenIterator(const BWFSRef *container, uint32_t flags, void **iterator) {
    if (!iterator || flags) return -50;
    NSString *directory = BWPathForFSRef(container);
    if (!directory) return -1401;
    struct stat attributes;
    if (stat(directory.fileSystemRepresentation, &attributes) != 0) return fileError(errno);
    if (!S_ISDIR(attributes.st_mode)) return -43;
    BWFabFilterDirectory *enumerator = [BWFabFilterDirectory new];
    enumerator.items = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:directory isDirectory:YES]
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsSubdirectoryDescendants errorHandler:nil];
    if (!enumerator.items) return -54;
    *iterator = (__bridge_retained void *)enumerator;
    return 0;
}

int16_t FSCloseIterator(void *iterator) {
    if (!iterator) return -50;
    CFRelease(iterator);
    return 0;
}

int16_t FSGetCatalogInfoBulk(void *iterator, unsigned long maximum, unsigned long *actual,
                             unsigned char *changed, uint32_t fields, BWCatalogInfo *catalog,
                             BWFSRef *refs, void *specs, BWHFSName *names) {
    if (!iterator || !actual || (fields & ~BWCatalogFields) || (fields && !catalog) || specs) return -50;
    *actual = 0;
    if (changed) *changed = 0;
    BWFabFilterDirectory *directory = (__bridge BWFabFilterDirectory *)iterator;
    while (*actual < maximum) {
        NSURL *entry = directory.items.nextObject;
        if (!entry) return -1417;
        struct stat attributes;
        if (stat(entry.fileSystemRepresentation, &attributes) != 0) continue;
        NSString *name = entry.lastPathComponent;
        if (names && name.length > 255) continue;
        unsigned long index = (*actual)++;
        if (fields & 0x02) {
            catalog[index].flags = (S_ISDIR(attributes.st_mode) ? 0x10 : 0) |
                ((attributes.st_mode & S_IWUSR) ? 0 : 1);
        }
        if (fields & 0x40) {
            uint64_t seconds = attributes.st_mtimespec.tv_sec + INT64_C(2082844800);
            catalog[index].highSeconds = (uint16_t)(seconds >> 32);
            catalog[index].lowSeconds = (uint32_t)seconds;
            catalog[index].fraction = attributes.st_mtimespec.tv_nsec * UINT64_C(65536) / UINT64_C(1000000000);
        }
        if (refs) BWStoreFSRef(entry.path, &refs[index]);
        if (names) {
            names[index].length = name.length;
            [name getCharacters:names[index].units range:NSMakeRange(0, name.length)];
        }
    }
    return 0;
}

void Microseconds(uint64_t *value) {
    if (value) *value = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000;
}

CFStringRef CSCopyMachineName(void) {
    return CFBridgingRetain(UIDevice.currentDevice.name);
}

int32_t LSOpenCFURLRef(CFURLRef target, CFURLRef *launched) {
    if (launched) *launched = NULL;
    NSURL *url = (__bridge NSURL *)target;
    UIApplication *app = UIApplication.sharedApplication;
    if (!NSThread.isMainThread || app.applicationState != UIApplicationStateActive || !url || ![app canOpenURL:url])
        return -10814;
    [app openURL:url options:@{} completionHandler:nil];
    return 0;
}
