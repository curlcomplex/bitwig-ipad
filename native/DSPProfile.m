#import <Foundation/Foundation.h>
#import "compat/LocalConfiguration.h"
#import "NativeAudioShared.h"
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/getsect.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    uintptr_t imageBase, textBase;
    unsigned long textSize;
} EngineText;

static uint64_t microseconds(time_value_t time) {
    return (uint64_t)time.seconds * 1000000 + time.microseconds;
}

static NSNumber *engineOffset(uintptr_t address, EngineText image) {
    if (address < image.textBase || address - image.textBase >= image.textSize) return nil;
    return @(address - image.imageBase);
}

static BOOL isAudioCandidate(const char *name) {
    if (strcmp(name, "BWAudioProxy") == 0) return YES;
    if (strncmp(name, "audio-", 6) != 0 || name[6] == '\0') return NO;
    return name[6 + strspn(name + 6, "0123456789")] == '\0';
}

static NSArray<NSNumber *> *originalFrames(thread_t thread, EngineText image) {
    NSMutableArray *frames = [NSMutableArray new];
#if defined(__arm64__)
    arm_thread_state64_t state = {};
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS)
        return frames;
    NSNumber *pc = engineOffset(arm_thread_state64_get_pc(state), image);
    NSNumber *lr = engineOffset(arm_thread_state64_get_lr(state), image);
    if (pc) [frames addObject:pc];
    if (lr) [frames addObject:lr];

    // The thread stays live. A changing or unreadable frame chain simply
    // ends this best-effort lookup. Never dereference the remote pointer.
    uintptr_t frame = arm_thread_state64_get_fp(state);
    uintptr_t stack = arm_thread_state64_get_sp(state);
    for (unsigned depth = 0; depth < 10; depth++) {
        if (frame < stack || frame - stack > 1024 * 1024 || (frame & 15)) break;
        uint64_t pair[2];
        vm_size_t read = 0;
        if (vm_read_overwrite(mach_task_self(), frame, sizeof(pair),
                                   (vm_address_t)pair, &read) != KERN_SUCCESS ||
            read != sizeof(pair)) break;
        NSNumber *caller = engineOffset(pair[1], image);
        if (caller) [frames addObject:caller];
        if (pair[0] <= frame) break;
        frame = pair[0];
    }
#endif
    return frames;
}

static NSArray<NSDictionary *> *threadSnapshot(EngineText image) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return @[];
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:count];
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_t thread = threads[i];
        thread_identifier_info_data_t idInfo = {};
        thread_basic_info_data_t basic = {};
        thread_extended_info_data_t extended = {};
        mach_msg_type_number_t idCount = THREAD_IDENTIFIER_INFO_COUNT;
        mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
        mach_msg_type_number_t extendedCount = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info(thread, THREAD_IDENTIFIER_INFO, (thread_info_t)&idInfo, &idCount) == KERN_SUCCESS &&
            thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&basic, &basicCount) == KERN_SUCCESS) {
            thread_info(thread, THREAD_EXTENDED_INFO, (thread_info_t)&extended, &extendedCount);
            extended.pth_name[sizeof(extended.pth_name) - 1] = '\0';
            BOOL audio = isAudioCandidate(extended.pth_name);
            [rows addObject:@{@"id": @(idInfo.thread_id),
                              @"name": @(extended.pth_name) ?: @"",
                              @"user_us": @(microseconds(basic.user_time)),
                              @"system_us": @(microseconds(basic.system_time)),
                              @"audio_candidate": @(audio),
                              @"engine_frames": audio ? originalFrames(thread, image) : @[]}];
        }
        mach_port_deallocate(mach_task_self(), thread);
    }
    if (threads) vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(*threads));
    return rows;
}

static NSDictionary *audioSnapshot(void) {
    NSURL *file = [BWSharedContainerURL() URLByAppendingPathComponent:@"BitwigUser/Audio/ring.bin"];
    int fd = open(file.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return @{};
    struct stat status;
    BWAudioRing *ring = MAP_FAILED;
    if (fstat(fd, &status) == 0 && status.st_size >= sizeof(BWAudioRing))
        ring = mmap(NULL, sizeof(BWAudioRing), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (ring == MAP_FAILED) return @{};
    NSDictionary *result = @{};
    if (ring->magic == BW_AUDIO_MAGIC)
        result = @{@"rate": @(ring->sampleRate), @"buffer_frames": @(ring->bufferFrames),
                   @"running": @(atomic_load(&ring->actualRunning)),
                   @"produced_frames": @(atomic_load(&ring->writeFrame)),
                   @"callbacks": @(atomic_load(&ring->callbacks)),
                   @"audible_frames": @(atomic_load(&ring->audibleFrames)),
                   @"underrun_frames": @(atomic_load(&ring->underrunFrames)),
                   @"error": @(atomic_load(&ring->error))};
    munmap(ring, sizeof(BWAudioRing));
    return result;
}

static NSUUID *consumeRequest(NSString *documents) {
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:documents error:nil]) {
        if (![name hasPrefix:@"dsp-profile."] || ![name hasSuffix:@".request"]) continue;
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@"."];
        if (parts.count != 3) continue;
        NSUUID *nonce = [[NSUUID alloc] initWithUUIDString:parts[1]];
        if (!nonce) continue;
        NSString *path = [documents stringByAppendingPathComponent:name];
        if (unlink(path.fileSystemRepresentation) == 0) return nonce;
    }
    return nil;
}

dispatch_source_t BWStartDSPProfile(const struct mach_header *header, NSString *documents) {
    EngineText image = {.imageBase = (uintptr_t)header};
    image.textBase = (uintptr_t)getsectiondata((const struct mach_header_64 *)header,
                                               "__TEXT", "__text", &image.textSize);
    dispatch_queue_t queue = dispatch_queue_create("org.bitwigipad.dsp-profile",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    __block NSMutableArray *samples = nil;
    __block NSUUID *nonce = nil;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              250 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            if (!samples) {
                nonce = consumeRequest(documents);
                if (!nonce) return;
                samples = [NSMutableArray new];
            }
            uint64_t begin = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            NSArray *threads = threadSnapshot(image);
            NSDictionary *audio = audioSnapshot();
            uint64_t end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            [samples addObject:@{@"begin_ns": @(begin), @"end_ns": @(end),
                                 @"audio": audio, @"threads": threads}];
            if (samples.count >= 25) {
                NSString *name = [NSString stringWithFormat:@"dsp-profile.%@.json", nonce.UUIDString];
                NSString *destination = [documents stringByAppendingPathComponent:name];
                NSDictionary *capture = @{@"pid": @(getpid()), @"nonce": nonce.UUIDString, @"samples": samples};
                NSData *data = [NSJSONSerialization dataWithJSONObject:capture options:0 error:nil];
                [data writeToFile:destination atomically:YES];
                samples = nil;
                nonce = nil;
            }
        }
    });
    dispatch_resume(timer);
    return timer;
}
