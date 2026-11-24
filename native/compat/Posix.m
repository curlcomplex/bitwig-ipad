#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <semaphore.h>
#include <dlfcn.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/mman.h>
#include <unistd.h>

// The desktop uses globally named POSIX shared memory. iPad app/extension
// sandboxes instead share real mmap-backed files within their App Group.
// Both binaries import this bridge, preserving open/exclusive/unlink semantics.
static NSString *sharedPath(const char *name) {
    if(!name||!name[0]){errno=EINVAL;return nil;}
    NSURL *group=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.felixgodden.bitwigipad"];
    if(!group){errno=EACCES;return nil;}
    NSURL *directory=[group URLByAppendingPathComponent:@"BitwigUser/Posix/SharedMemory" isDirectory:YES];
    NSError *error=nil;
    if(![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]){errno=EACCES;return nil;}
    NSMutableString *encoded=[NSMutableString new];
    // shm names with or without the optional leading slash identify one object.
    if(*name=='/')name++;
    for(const unsigned char *p=(const unsigned char*)name;*p;p++)[encoded appendFormat:@"%02x",*p];
    return [[directory URLByAppendingPathComponent:encoded] path];
}
int shm_open(const char *name,int flags,...) {
    mode_t mode=0;
    if(flags&O_CREAT){va_list arguments;va_start(arguments,flags);mode=(mode_t)va_arg(arguments,int);va_end(arguments);}
    @autoreleasepool {
        NSString *path=sharedPath(name);if(!path)return -1;
        int fd=open(path.fileSystemRepresentation,flags|O_CLOEXEC,mode);
        if(fd<0)fprintf(stderr,"[native IPC] shared memory open failed: %s (%d)\n",name,errno);
        return fd;
    }
}
int shm_unlink(const char *name) {
    @autoreleasepool {NSString *path=sharedPath(name);return path?unlink(path.fileSystemRepresentation):-1;}
}

// Apple's App Group IPC rules require <group>/<name>, within PSEMNAMLEN.
// A separate short group leaves room for a stable 96-bit name digest.
static NSString *semaphoreName(const char *name) {
    if(!name||!name[0]){errno=EINVAL;return nil;}
    if(*name=='/')name++;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(name,(CC_LONG)strlen(name),digest);
    NSString *key=[[NSData dataWithBytes:digest length:12] base64EncodedStringWithOptions:0];
    key=[[key stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    return [@"group.fg.bw/" stringByAppendingString:key];
}
sem_t *sem_open(const char *name,int flags,...) {
    mode_t mode=0;unsigned value=0;
    if(flags&O_CREAT){va_list args;va_start(args,flags);mode=(mode_t)va_arg(args,int);value=va_arg(args,unsigned);va_end(args);}
    @autoreleasepool {
        NSString *mapped=semaphoreName(name);if(!mapped)return SEM_FAILED;
        static sem_t *(*systemOpen)(const char*,int,...);static dispatch_once_t once;
        dispatch_once(&once,^{systemOpen=dlsym(dlopen("/usr/lib/libSystem.B.dylib",RTLD_NOW),"sem_open");});
        sem_t *result=systemOpen(mapped.UTF8String,flags,mode,value);
        if(result==SEM_FAILED)fprintf(stderr,"[native IPC] semaphore %s failed (%d)\n",mapped.UTF8String,errno);
        return result;
    }
}
int sem_unlink(const char *name) {
    @autoreleasepool {
        NSString *mapped=semaphoreName(name);if(!mapped)return -1;
        static int (*systemUnlink)(const char*);static dispatch_once_t once;
        dispatch_once(&once,^{systemUnlink=dlsym(dlopen("/usr/lib/libSystem.B.dylib",RTLD_NOW),"sem_unlink");});
        return systemUnlink(mapped.UTF8String);
    }
}
