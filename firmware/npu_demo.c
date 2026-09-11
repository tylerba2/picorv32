#include "npu_gemm.h"

/* Call from your platform's main after reset. Return 0 on success.
 * Tail padding lets DMA fetch the final complete 32-bit input word. */
int npu_demo(void);
int npu_demo(void)
{
    static const int8_t a[8] __attribute__((aligned(4))) = {1, 2, 3, 4, 5, 6, 0, 0};
    static const int8_t b[8] __attribute__((aligned(4))) = {7, 8, 9, 10, 11, 12, 0, 0};
    static int32_t c[4] __attribute__((aligned(4)));
    static const int32_t expected[4] = {58, 64, 139, 154};
    const struct npu_gemm_job job = {
        (uint32_t)(uintptr_t)a, (uint32_t)(uintptr_t)b, (uint32_t)(uintptr_t)c,
        2, 2, 3, 0, 0
    };
    npu_gemm_submit(&job, 77);
    uint32_t status = npu_wait();
    if (!(status & NPU_STATUS_DONE) || NPU_STATUS_ERROR(status) || npu_completed_tag() != 77)
        return -1;
    for (int i = 0; i < 4; ++i)
        if (c[i] != expected[i])
            return i + 1;
    return 0;
}
