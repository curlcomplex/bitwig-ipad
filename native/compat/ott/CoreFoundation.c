#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>
#include <string.h>

extern int32_t FSRefMakePath(const void *ref, unsigned char *buffer, uint32_t capacity);

CFURLRef CFURLCreateFromFSRef(CFAllocatorRef allocator, const struct FSRef *ref) {
    unsigned char path[PATH_MAX];
    if (FSRefMakePath(ref, path, sizeof(path))) return NULL;
    return CFURLCreateFromFileSystemRepresentation(allocator, path, strlen((const char *)path), true);
}
