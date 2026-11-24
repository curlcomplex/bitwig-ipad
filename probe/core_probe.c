/* Uses Henge 0.3's unmodified core and native-vs-JIT test harness. */
#include "harness.h"
#include <stdlib.h>
DECLARE_PROGRAM(arith);
DECLARE_PROGRAM(loop);
DECLARE_PROGRAM(simd_fp);
extern const char jit_programs_begin[], jit_programs_finish[];
int run_henge_probe(void) {
    static HvMachine machine;
    if (hv_machine_init(&machine, 4 << 20) != 0) {
        puts("FAIL: simulator could not allocate Henge executable memory");
        return 1;
    }
    puts("PASS: upstream split JIT mapping allocated");
    hv_machine_add_ram(&machine, (uint64_t)(uintptr_t)jit_programs_begin,
                       jit_programs_finish - jit_programs_begin, (void *)jit_programs_begin, 1);
    uint8_t *stack = aligned_alloc(16384, 65536);
    if (!stack) return 2;
    hv_machine_add_ram(&machine, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
    const TestProgram programs[] = {TEST_PROGRAM(arith), TEST_PROGRAM(loop), TEST_PROGRAM(simd_fp)};
    int failures = 0;
    for (int i = 0; i < 3; ++i) {
        static HvCpu initial, native, translated;
        memset(&initial, 0, sizeof initial);
        seed_cpu(&initial, i + 1, (uint64_t)(uintptr_t)stack + 32768);
        run_native(&programs[i], &initial, &native, NULL);
        int bad = run_jit(&machine, &programs[i], &initial, &translated, NULL);
        if (!bad) bad = compare_cpus(programs[i].name, &native, &translated);
        printf("%s: %s native versus translated CPU state\n", bad ? "FAIL" : "PASS", programs[i].name);
        failures += bad != 0;
    }
    puts("Scope: CPU core only. macOS, graphics, audio, Bitwig and physical-device JIT are untested.");
    return failures != 0;
}
