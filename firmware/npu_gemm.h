#ifndef PICORV32_NPU_GEMM_H
#define PICORV32_NPU_GEMM_H

#include "accel.h"

#ifndef PICORV32_NPU_STATUS_BASE
#define PICORV32_NPU_STATUS_BASE UINT32_C(0xf0000000)
#endif

#define NPU_GEMM_CMD 0
#define NPU_WAIT_CMD 1
#define NPU_GEMM_ACCUMULATE UINT32_C(1)
#define NPU_STATUS_BUSY UINT32_C(1)
#define NPU_STATUS_DONE UINT32_C(2)
#define NPU_STATUS_ERROR(status) (((status) >> 8) & UINT32_C(255))

enum npu_gemm_error {
    NPU_OK = 0,
    NPU_BAD_COMMAND = 1,
    NPU_BAD_ALIGNMENT_OR_DESCRIPTOR_ADDRESS = 2,
    NPU_BAD_DIMENSIONS = 3,
    NPU_BAD_FLAGS = 4,
    NPU_ADDRESS_OVERFLOW = 5
};

/* Eight little-endian words. All addresses are accelerator-visible addresses.
 * A and B are packed signed bytes; C contains signed 32-bit words. All three
 * buffers start on a 4-byte boundary; pad A and B allocations to whole words. */
struct npu_gemm_job {
    uint32_t a_addr;
    uint32_t b_addr;
    uint32_t c_addr;
    uint32_t m;
    uint32_t n;
    uint32_t k;
    uint32_t flags;
    uint32_t reserved;
};

static inline uint32_t npu_status(void)
{
    return *(volatile const uint32_t *)(uintptr_t)PICORV32_NPU_STATUS_BASE;
}

static inline uint32_t npu_completed_tag(void)
{
    /* The register holds the active tag while busy and completed tag when done. */
    return *(volatile const uint32_t *)(uintptr_t)(PICORV32_NPU_STATUS_BASE + 4);
}

static inline void npu_gemm_submit(const struct npu_gemm_job *job, uint32_t tag)
{
    picorv32_accel_submit(NPU_GEMM_CMD, job, tag);
}

static inline uint32_t npu_wait(void)
{
    /* Blocks until idle. Preserves DONE, error and tag; does not submit a job.
     * Memory ordering assumes the non-posted native bus in picorv32_npu. */
    picorv32_accel_submit(NPU_WAIT_CMD, 0, 0);
    return npu_status();
}

#endif
