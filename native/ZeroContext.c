// OpenJDK Mobile Zero's BSD context accessors still abort with ShouldNotCall.
// Supply the actual ARM64 iOS signal context operations at static link time.
#include <sys/ucontext.h>
#include <mach/arm/thread_status.h>
#include <stdint.h>

unsigned char *BWZeroGetPC(const ucontext_t *context)
    __asm__("__ZN2os5Posix15ucontext_get_pcEPK17__darwin_ucontext");
void BWZeroSetPC(ucontext_t *context, unsigned char *pc)
    __asm__("__ZN2os5Posix15ucontext_set_pcEP17__darwin_ucontextPh");

unsigned char *BWZeroGetPC(const ucontext_t *context) {
    return (unsigned char *)(uintptr_t)arm_thread_state64_get_pc(context->uc_mcontext->__ss);
}
void BWZeroSetPC(ucontext_t *context, unsigned char *pc) {
    arm_thread_state64_set_pc_fptr(context->uc_mcontext->__ss, pc);
}
