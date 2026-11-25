// Exercise the original 6.1.7 caller's directional size/global data sequence.
#import "../native/compat/LocalConfiguration.h"
#include <assert.h>

static NSURL *fixtureContainer;
static NSURL *testContainerURL(void) { return fixtureContainer; }

#define BWSharedContainerURL testContainerURL
#import "../native/compat/AudioHAL.m"
#undef BWSharedContainerURL

int main(void) {
    @autoreleasepool {
        fixtureContainer = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSURL *directory = [fixtureContainer URLByAppendingPathComponent:@"BitwigUser/Audio" isDirectory:YES];
        assert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]);
        NSURL *ringURL = [directory URLByAppendingPathComponent:@"ring.bin"];
        int fd = open(ringURL.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
        assert(fd >= 0 && ftruncate(fd, sizeof(BWAudioRing)) == 0);
        BWAudioRing *ring = mmap(NULL, sizeof(BWAudioRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        assert(ring != MAP_FAILED);
        ring->magic = BW_AUDIO_MAGIC;
        atomic_store(&ring->routeGeneration, 2);
        NSDictionary *format = @{
            @"generation": @2, @"name": @"Fixture", @"rate": @48000, @"frames": @1120,
            @"input_channels": @1, @"channels": @2
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:format options:0 error:nil];
        assert([json writeToURL:[directory URLByAppendingPathComponent:@"route.json"] atomically:YES]);

        AudioObjectPropertyAddress owned = {
            kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
        };
        AudioObjectPropertyAddress streams = {
            kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain
        };
        UInt32 value[2];
        UInt32 size;
        for (unsigned input = 0; input <= 1; input++) {
            streams.mScope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
            assert(AudioObjectGetPropertyDataSize(BWDevice, &streams, 0, NULL, &size) == noErr);
            assert(size == sizeof(UInt32));
            assert(AudioObjectGetPropertyData(BWDevice, &owned, 0, NULL, &size, value) == noErr);
            assert(size == sizeof(UInt32));
            assert(value[0] == (input ? BWInputStream : BWStream));
            assert(AudioObjectGetPropertyData(BWDevice, &owned, 0, NULL, &size, value) == kAudioHardwareBadPropertySizeError);
        }
        assert(AudioObjectGetPropertyDataSize(BWDevice, &owned, 0, NULL, &size) == noErr);
        assert(size == sizeof(value));
        assert(AudioObjectGetPropertyData(BWDevice, &owned, 0, NULL, &size, value) == noErr);
        assert(size == sizeof(value) && value[0] == BWStream && value[1] == BWInputStream);

        assert(AudioObjectGetPropertyDataSize(BWDevice, &streams, 0, NULL, &size) == noErr);
        assert(AudioObjectGetPropertyData(BWDevice, &streams, 0, NULL, &size, value) == noErr);
        assert(value[0] == BWInputStream);
        assert(AudioObjectGetPropertyData(BWDevice, &owned, 0, NULL, &size, value) == kAudioHardwareBadPropertySizeError);
        munmap(ring, sizeof(*ring));
        assert([NSFileManager.defaultManager removeItemAtURL:fixtureContainer error:nil]);
        puts("PASS: original directional pairs, full owned list and one-shot undersize rejection");
    }
}
