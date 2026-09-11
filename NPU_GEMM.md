# PicoRV32 GEMM accelerator

`npu_gemm.v` implements signed INT8 matrix multiplication with INT32 outputs:

```
C[m,n] = sum(A[m,k] * B[k,n])       flags = 0
C[m,n] += sum(A[m,k] * B[k,n])      flags = 1
```

Matrices are contiguous and row-major. INT32 arithmetic wraps modulo 2^32;
there is no saturation, requantization, transpose, or floating-point support.
This is a first GEMM compute engine for an NPU, with no neural-network scheduler
or activation units. General BLAS alpha/beta scaling is not implemented.

## Architecture

```text
PicoRV32 -- custom instruction --> command receiver / descriptor reader
    |                                      |
    |                                 A and B buffers
    |                                      |
    |                            MAX_N parallel INT8 MACs
    |                                      |
    |                               INT32 row accumulators
    |                                      |
    +-- CPU memory --+               DMA read/write port
                     |                     |
                     +-- locked round-robin arbiter -- external native memory
    |
    +-- local status registers
```

The engine reads the descriptor, loads A and B with 32-bit memory reads, then
computes one output row at a time. Each computation cycle broadcasts one A
element to `MAX_N` signed multipliers, accumulating the active `N` columns.
For accumulation mode it first reads the existing output row. It writes the
finished row before starting the next row. Completion follows acceptance of
the final output write.

The default parameters are `MAX_M=16`, `MAX_N=16`, and `MAX_K=64`. Each job can
use any positive M, N, K within those limits. The default hardware has 16 MAC
lanes, 2,048 bytes of input buffers, and 64 bytes of accumulators. MAC execution
takes `M*K` cycles, excluding descriptor/input/output transfers and control.
The current buffer RTL uses asynchronous indexed reads and four-byte writes;
RAM/DSP inference and achievable frequency depend on synthesis and the target.
It does not yet provide a banked SRAM implementation or overlap DMA with MACs.

Parameters must be positive and no greater than 65535, with practical hardware
resource limits applying well before that bound. Larger matrices need software
tiling and packing into contiguous tiles: accumulate successive K tiles with
flag 1 after the first tile. There is no automatic tiler or stride support.

## Integration

Use `picorv32_npu.v` as the top-level CPU wrapper, compiling it together with
`picorv32.v` and `npu_gemm.v`. It enables the existing accelerator instruction
and exposes one shared PicoRV32 native memory port:

```verilog
picorv32_npu #(.MAX_M(16), .MAX_N(16), .MAX_K(64)) system (
    .clk(clk), .resetn(resetn), .trap(trap),
    .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
    .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
    .mem_rdata(mem_rdata),
    .npu_busy(npu_busy), .npu_done(npu_done), .npu_error(npu_error)
);
```

Each external memory request completes on a rising edge with valid and ready.
The arbiter retains the selected request while stalled and alternates between
CPU and DMA when both request memory. The CPU can execute during GEMM. The
wrapper does not use PicoRV32's look-ahead memory port. DMA requests have
`mem_instr=0`. Reads use zero write strobes; output writes use all four strobes.
Memory responses and accepted writes must be ordered and non-posted. Both
masters and memory use the same clock/reset. AXI/Wishbone adapters, caches, and
clock-domain bridges are outside this wrapper.

Alternatively connect `npu_gemm` directly to the five accelerator command ports
on your existing CPU and supply its memory master and status integration.
`done` is sticky status, not a one-cycle pulse; no IRQ is wired in this wrapper.

## Commands

The instruction encoding remains the one documented in [ACCELERATOR.md](ACCELERATOR.md).
The CPU forwards the command ID and both register values unchanged.

| Command | rs1 value | rs2 value | Behavior |
| --- | --- | --- | --- |
| 0: GEMM | Descriptor address | Job tag | Accept, clear old status, begin work |
| 1: WAIT | Ignored | Ignored | Accept only when idle; preserve completion status |

All commands are backpressured while busy; there is one job in flight and no
queue. GEMM retires on acceptance. WAIT stalls the CPU until the engine is idle;
it does not return a register value. Read MMIO afterward to distinguish success
from failure. A new GEMM replaces the previous completion/tag, so inspect status
before submitting the next job. Unsupported commands complete with error 1.
WAIT immediately after reset is allowed but does not set DONE.

## Descriptor

Eight little-endian 32-bit words at a four-byte-aligned address:

| Byte offset | Field | Meaning |
| --- | --- | --- |
| 0 | a_addr | Aligned address of M*K signed bytes |
| 4 | b_addr | Aligned address of K*N signed bytes |
| 8 | c_addr | Aligned address of M*N signed 32-bit outputs |
| 12 | m | Rows of A and C |
| 16 | n | Columns of B and C |
| 20 | k | Reduction length |
| 24 | flags | 0 for overwrite; 1 for accumulate |
| 28 | reserved | Must be zero |

Pad A and B allocations to a multiple of four bytes: the last DMA read is a
whole word, although padding bytes do not participate in arithmetic. All buffers
and the descriptor must be in ordinary shared memory accessible to both masters,
outside the status-register window. Keep the descriptor and buffers alive and
unchanged until completion. In accumulate mode initialize C before submission.
Addresses are physical bus addresses; there is no address translation.

The engine rejects malformed descriptors before reading matrices or writing C.
It checks alignment, dimensions, flags, reserved fields, and 32-bit address
wraparound. It cannot validate whether a physical address is mapped. The native
interface has no bus-error response or timeout; memory must eventually assert
ready. Reset cancels further work and clears status but does not undo already
accepted output writes. Reset the memory interface with the CPU/NPU to cancel
pending transfers consistently.

## Status registers

The wrapper reserves 16 bytes at `STATUS_BASE` (default `0xf0000000`, must be
16-byte aligned). Reads are handled locally; writes are acknowledged and ignored.
If overriding the RTL base, also define `PICORV32_NPU_STATUS_BASE` for firmware.

| Offset | Contents |
| --- | --- |
| 0 | Bit 0 BUSY; bit 1 DONE; bits 15:8 error code; all other bits zero |
| 4 | Active/latest job tag |
| 8 | MAX_M in bits 15:0; upper half zero |
| 12 | MAX_K in bits 31:16; MAX_N in bits 15:0 |

DONE is set on both success and failure. DONE/error clear when a new GEMM or
unsupported command is accepted, and all status clears on reset.

| Error | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Unsupported command |
| 2 | Misaligned address or descriptor would cross the address-space end |
| 3 | Zero or out-of-limit dimension |
| 4 | Unsupported flags or nonzero reserved word |
| 5 | Matrix transfer would cross the address-space end |

## Software and verification

[firmware/npu_gemm.h](firmware/npu_gemm.h) defines the descriptor and submission,
wait, and status helpers. [firmware/npu_demo.c](firmware/npu_demo.c) supplies a
complete callable 2x3 times 3x2 example. The job remains in scope until WAIT
completes. The helper's compiler memory clobbers and this wrapper's ordered
shared bus provide visibility; a different memory system needs its own cache
maintenance and hardware ordering.

Run `make test_npu test_accel`, or without make/toolchain:

```sh
iverilog -g2012 -s testbench_npu -o testbench_npu.vvp testbench_npu.v npu_gemm.v picorv32_npu.v picorv32.v
vvp -N testbench_npu.vvp
iverilog -g2012 -s testbench_accel -o testbench_accel.vvp testbench_accel.v picorv32.v
vvp -N testbench_accel.vvp
```

The self-checking NPU bench compares 54 jobs against an independent integer
reference across default and odd-sized parameter limits. It covers signed
extrema, rectangular and maximum dimensions, overwrite, accumulation and INT32
wraparound, input tails, output guards, back-to-back jobs, WAIT backpressure,
invalid commands/descriptors, reset with a stalled transfer, and request
stability during memory stalls, and immediate memory responses. A real PicoRV32 instruction stream submits a
GEMM, performs a concurrent memory read, waits, and copies MMIO status/tag and
all four output elements through the shared memory bus for checking.
