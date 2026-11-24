// LLVM 21.1.8 SectionMemoryManager adaptation for the supported Bitwig ARM64 engines.
// LLVM emits/relocates in its own staging memory; mapSectionAddress assigns the
// real RX addresses before relocation, and finalize copies into prepared aliases.
#import <Foundation/Foundation.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <uuid/uuid.h>
#include <libkern/OSCacheControl.h>
#include <dlfcn.h>
#include <pthread.h>
#include <errno.h>
#include <unistd.h>
#include <stdbool.h>
extern int csops(pid_t,unsigned int,void*,size_t);
typedef struct Arena {uintptr_t rx,rw;size_t bytes,pages;unsigned char *used;struct Arena *next;} Arena;
typedef struct Section {void *manager,*local;size_t size,first,pages;uintptr_t rx,rw;bool mapped;Arena *arena;struct Section *next;} Section;
typedef struct {const char *data;size_t size;} LLVMStringRef;
static Arena *arenas;
static Section *sections;
static size_t pageSize,finalizations,finalizedBytes;
static bool ready;
static pthread_mutex_t memoryLock=PTHREAD_MUTEX_INITIALIZER;
static int (*systemUnmap)(void*,size_t);
static int (*systemProtect)(void*,size_t,int);
static void *(*originalAllocate)(void*,size_t,unsigned,unsigned,LLVMStringRef);
static bool (*originalFinalize)(void*,void*);
static void (*originalNotify)(void*,void*,const void*);
static void (*mapSection)(void*,const void*,uint64_t);
static void resolve(void){static dispatch_once_t once;dispatch_once(&once,^{void *lib=dlopen("/usr/lib/libSystem.B.dylib",RTLD_NOW);systemUnmap=dlsym(lib,"munmap");systemProtect=dlsym(lib,"mprotect");});}
__attribute__((naked,noinline)) static void *allocatePages(size_t bytes){__asm__("brk #0x72\n ret");}
static void report(NSString *phase,int error) {
    @autoreleasepool {
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSDictionary *value=@{@"pid":@(getpid()),@"phase":phase,@"error":@(error),@"finalizations":@(finalizations),@"finalized_bytes":@(finalizedBytes)};
        [[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"engine-jit-state.json"] atomically:YES];
    }
}
static Arena *newArena(size_t minimum) {
    size_t bytes=MAX((size_t)32*1024*1024,(minimum+pageSize-1)&~(pageSize-1));
    uintptr_t rx=(uintptr_t)allocatePages(bytes);
    if(!rx||rx==(uintptr_t)MAP_FAILED)return NULL;
    vm_address_t rw=0;vm_prot_t current=0,maximum=0;
    kern_return_t result=vm_remap(mach_task_self(),&rw,bytes,0,VM_FLAGS_ANYWHERE,mach_task_self(),rx,FALSE,&current,&maximum,VM_INHERIT_NONE);
    if(!result)result=vm_protect(mach_task_self(),rw,bytes,FALSE,VM_PROT_READ|VM_PROT_WRITE);
    if(result){report(@"writable alias creation failed",result);return NULL;}
    Arena *arena=calloc(1,sizeof(*arena));
    if(!arena)return NULL;
    arena->rx=rx;arena->rw=rw;arena->bytes=bytes;arena->pages=bytes/pageSize;arena->used=calloc(arena->pages,1);
    if(!arena->used){free(arena);return NULL;}
    arena->next=arenas;arenas=arena;return arena;
}
static void *allocateCode(void *manager,size_t size,unsigned alignment,unsigned sectionID,LLVMStringRef name) {
    void *local=originalAllocate(manager,size,alignment,sectionID,name);
    if(!local)return NULL;
    pthread_mutex_lock(&memoryLock);
    size_t needed=(MAX(size,(size_t)1)+MAX(alignment,1u)-1+pageSize-1)/pageSize;
    Arena *chosen=NULL;size_t first=0;
    for(Arena *a=arenas;a&&!chosen;a=a->next){
        size_t run=0;
        for(size_t i=0;i<a->pages;i++){run=a->used[i]?0:run+1;if(run==needed){chosen=a;first=i+1-needed;break;}}
    }
    if(!chosen)chosen=newArena(needed*pageSize);
    Section *section=chosen?calloc(1,sizeof(*section)):NULL;
    if(!section){pthread_mutex_unlock(&memoryLock);report(@"code arena allocation failed",ENOMEM);return NULL;}
    memset(chosen->used+first,1,needed);
    uintptr_t rx=(chosen->rx+first*pageSize+MAX(alignment,1u)-1)&~((uintptr_t)MAX(alignment,1u)-1);
    *section=(Section){.manager=manager,.local=local,.size=size,.first=first,.pages=needed,.rx=rx,.rw=chosen->rw+(rx-chosen->rx),.arena=chosen,.next=sections};
    sections=section;
    pthread_mutex_unlock(&memoryLock);return local;
}
static void notifyObject(void *manager,void *engine,const void *object) {
    originalNotify(manager,engine,object);
    pthread_mutex_lock(&memoryLock);
    for(Section *s=sections;s;s=s->next)if(s->manager==manager&&!s->mapped){mapSection(engine,s->local,s->rx);s->mapped=true;}
    pthread_mutex_unlock(&memoryLock);
}
static bool finalizeMemory(void *manager,void *errorString) {
    report(@"LLVM finalization entered",0);
    bool error=originalFinalize(manager,errorString);if(error){report(@"LLVM staging finalization failed",errno);return error;}
    pthread_mutex_lock(&memoryLock);
    for(Section *s=sections;s;s=s->next)if(s->manager==manager){
        memcpy((void*)s->rw,s->local,s->size);
        sys_icache_invalidate((void*)s->rx,s->size);
        finalizedBytes+=s->size;
    }
    finalizations++;report(@"LLVM code finalized into executable view",0);
    pthread_mutex_unlock(&memoryLock);return false;
}
int mprotect(void *address,size_t length,int protection) {
    resolve();
    // LLVM's local code is relocation staging only. Execution uses the prepared
    // RX mapping, so the original finalizer must not request executable staging.
    if(ready&&(protection&PROT_EXEC)){
        pthread_mutex_lock(&memoryLock);
        uintptr_t start=(uintptr_t)address;
        for(Section *s=sections;s;s=s->next){
            uintptr_t local=(uintptr_t)s->local;
            if(local>=start&&local-start<length&&s->size<=length-(local-start)){
                protection=(protection&~PROT_EXEC)|PROT_READ;break;
            }
        }
        pthread_mutex_unlock(&memoryLock);
    }
    return systemProtect(address,length,protection);
}
int munmap(void *address,size_t length) {
    resolve();if(!ready)return systemUnmap(address,length);
    pthread_mutex_lock(&memoryLock);
    int result=systemUnmap(address,length);
    if(!result){
        Section **cursor=&sections;
        while(*cursor){Section *s=*cursor;uintptr_t local=(uintptr_t)s->local,start=(uintptr_t)address;
            if(local>=start&&local-start<length&&s->size<=length-(local-start)){
                memset(s->arena->used+s->first,0,s->pages);*cursor=s->next;free(s);
            }else cursor=&s->next;
        }
    }
    pthread_mutex_unlock(&memoryLock);return result;
}
bool BWPrepareEngineJIT(void) {
    resolve();pageSize=(size_t)getpagesize();report(@"waiting for embedded helper",0);
    uint32_t flags=0;unsigned waits=0;
    while((csops(getpid(),0,&flags,sizeof(flags))||!(flags&0x10000000))&&waits++<1200)usleep(50000);
    if(!(flags&0x10000000)){report(@"helper attach timed out",ETIMEDOUT);return false;}
    report(@"preparing executable arena",0);Arena *a=newArena(pageSize);if(!a)return false;
    uint32_t *writer=(uint32_t*)a->rw;writer[0]=0x52800540;writer[1]=0xd65f03c0;
    sys_icache_invalidate((void*)a->rx,8);
    if(((int(*)(void))a->rx)()!=42){report(@"first execution mismatch",0);return false;}
    writer[0]=0x52800560;sys_icache_invalidate((void*)a->rx,8);
    if(((int(*)(void))a->rx)()!=43){report(@"rewritten execution mismatch",0);return false;}
    ready=true;report(@"execution and rewrite passed",0);return true;
}
typedef struct {
    uuid_t uuid;
    uintptr_t memoryManager, mcjit;
    uintptr_t allocate, finalize, notify, map;
} EngineABI;

static const EngineABI engineABIs[] = {
    // ARM64 6.1.4, LLVM 21.1.8
    {{0xb7,0xf7,0x33,0xf9,0x83,0x1b,0x3a,0xf8,0xb5,0x89,0x59,0x6b,0x86,0x93,0xbe,0x9a},
     0x3e26cc0, 0x3e26948, 0x3ef228, 0x3ef238, 0x3ef964, 0x3e6fd8},
    // ARM64 6.1.7, LLVM 21.1.8
    {{0x61,0x52,0xb2,0xae,0x4f,0x73,0x3e,0xfb,0xa7,0x0d,0x1d,0x82,0x43,0x42,0x2b,0xa4},
     0x3e32cc0, 0x3e32948, 0x3ee510, 0x3ee520, 0x3eec4c, 0x3e62c0},
};

static const EngineABI *engineABI(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64)
        return NULL;
    const unsigned char *command = (const unsigned char *)(header + 1);
    size_t left = header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && left >= sizeof(struct load_command); i++) {
        const struct load_command *load = (const struct load_command *)command;
        if (load->cmdsize < sizeof(*load) || load->cmdsize > left) break;
        if (load->cmd == LC_UUID && load->cmdsize == sizeof(struct uuid_command)) {
            const struct uuid_command *imageUUID = (const struct uuid_command *)load;
            for (size_t j = 0; j < sizeof(engineABIs) / sizeof(engineABIs[0]); j++)
                if (uuid_compare(imageUUID->uuid, engineABIs[j].uuid) == 0)
                    return &engineABIs[j];
            break;
        }
        command += load->cmdsize;
        left -= load->cmdsize;
    }
    return NULL;
}

bool BWInstallEngineMemoryManager(const void *header) {
    const EngineABI *abi = engineABI(header);
    if (!abi) {
        report(@"Unsupported ARM64 engine UUID", EINVAL);
        return false;
    }
    uintptr_t base = (uintptr_t)header;
    void **vtable = (void **)(base + abi->memoryManager);
    void **mcjit = (void **)(base + abi->mcjit);
    // Check the fixed-up callbacks in the loaded image before changing table data.
    if (vtable[2] != (void *)(base + abi->allocate) ||
        vtable[10] != (void *)(base + abi->finalize) ||
        vtable[13] != (void *)(base + abi->notify) ||
        mcjit[12] != (void *)(base + abi->map)) {
        report(@"LLVM memory manager ABI does not match adapted payload",EINVAL);return false;
    }
    originalAllocate=vtable[2];originalFinalize=vtable[10];originalNotify=vtable[13];mapSection=mcjit[12];
    vm_address_t page=(uintptr_t)vtable&~(pageSize-1);
    kern_return_t result=vm_protect(mach_task_self(),page,pageSize,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
    if(result){report(@"LLVM vtable data adaptation failed",result);return false;}
    vtable[2]=(void*)allocateCode;vtable[10]=(void*)finalizeMemory;vtable[13]=(void*)notifyObject;
    result=vm_protect(mach_task_self(),page,pageSize,FALSE,VM_PROT_READ);
    if(result){report(@"LLVM vtable data protection restore failed",result);return false;}
    report(@"LLVM dual-view code memory installed",0);return true;
}
