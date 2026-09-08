#ifndef PICORV32_ACCEL_H
#define PICORV32_ACCEL_H

#include <stdint.h>

/* command must be a compile-time constant in [0, 127]. Each argument is a
 * 32-bit scalar or an accelerator-visible address. Returns on acceptance,
 * not completion. The memory clobber orders compiler accesses, not DMA. */
#define picorv32_accel_submit(command, arg0, arg1) \
    __asm__ volatile (".insn r 0x2b, 0, %0, x0, %1, %2" \
                      : : "i" (command), "r" ((uint32_t)(uintptr_t)(arg0)), \
                          "r" ((uint32_t)(uintptr_t)(arg1)) : "memory")

#endif
