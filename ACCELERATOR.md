# Accelerator command instruction

Set `ENABLE_ACCEL = 1` on `picorv32`, `picorv32_axi`, or `picorv32_wb`.
The default is `0`, so existing named-port instantiations can omit the new
ports. Positional port instantiations need the five appended ports. External
`ENABLE_PCPI` is not required. Multiply, divide, and IRQ support can be enabled
alongside this feature.

## Instruction

`ACCEL command, rs1, rs2` submits a command with two raw 32-bit values. Either
value may be a pointer or scalar; the accelerator defines their meaning.
No CPU register is written. `command` is a 7-bit immediate (0 through 127).

| Bits | Value |
| --- | --- |
| 31:25 (funct7) | Command ID |
| 24:20 | rs2 register number |
| 19:15 | rs1 register number |
| 14:12 (funct3) | 0 |
| 11:7 (rd) | 0 (x0) |
| 6:0 | 0x2b (custom-1) |

The [RISC-V opcode map](https://docs.riscv.org/reference/isa/unpriv/rv-32-64g.html)
reserves custom-1 for custom extensions. PicoRV32's IRQ instructions use
custom-0, so this encoding does not overlap them. Other funct3/rd combinations
are not handled by this extension. When disabled, the encoding follows the
normal unsupported-instruction path (including external PCPI, if enabled).

GNU assembly syntax (no compiler backend change needed):

```asm
# Submit command 0 with the values in a0 and a1.
.insn r 0x2b, 0, 0, x0, a0, a1
```

## Hardware connection

| Port | CPU direction | Meaning |
| --- | --- | --- |
| `accel_valid` | Output | Command and arguments are valid |
| `accel_ready` | Input | Accelerator can accept a command on this edge |
| `accel_cmd[6:0]` | Output | Command ID |
| `accel_arg0[31:0]` | Output | Value read from rs1 |
| `accel_arg1[31:0]` | Output | Value read from rs2 |

Connect these ports directly to your accelerator's command receiver:

```verilog
wire accel_valid, accel_ready;
wire [6:0] accel_cmd;
wire [31:0] accel_arg0, accel_arg1;

picorv32 #(.ENABLE_ACCEL(1)) cpu (
    .clk(clk), .resetn(resetn),
    // Connect the CPU memory and other existing ports here.
    .accel_valid(accel_valid), .accel_ready(accel_ready),
    .accel_cmd(accel_cmd),
    .accel_arg0(accel_arg0), .accel_arg1(accel_arg1)
);

assign accel_ready = !busy;
always @(posedge clk) begin
    if (!resetn) begin
        busy <= 0;
    end else begin
        if (accel_valid && accel_ready) begin
            // Declare these registers in your accelerator.
            saved_command <= accel_cmd;
            saved_arg0 <= accel_arg0;
            saved_arg1 <= accel_arg1;
            busy <= 1;
            // Begin your accelerator's state machine here.
        end
        if (busy && work_done)
            busy <= 0;
    end
end
```

The transfer occurs on a rising clock edge with both `accel_valid` and
`accel_ready` high. The CPU holds valid, command, and arguments stable while
ready is low, without the normal PCPI timeout. A receiver must capture each
transfer once; `accel_valid` alone is not a one-cycle start pulse. Payload
outputs are meaningful only when valid is high. Reset suppresses valid and
discards an unaccepted request. Use the CPU clock/reset for the receiver;
another clock domain requires a handshake bridge or asynchronous FIFO.

The instruction retires when accepted, and the CPU continues while the
accelerator works. Completion/status must be supplied separately, for example
through memory-mapped registers or an IRQ. If ready never rises, the CPU stays
on this instruction; it cannot service an IRQ to resolve that stall. Reset can
abort it. An already accepted request belongs to the accelerator, whose reset
and cancellation behavior must be defined by your design.

This implementation uses PicoRV32's internal PCPI operand/execution path.
External PCPI still sees the instruction, but its responses are ignored for
the accelerator encoding while `ENABLE_ACCEL=1`. External coprocessors must
not execute side effects for this reserved encoding.

## C usage and larger argument sets

Include [firmware/accel.h](firmware/accel.h) with a RISC-V compiler/assembler
supporting `.insn`. The command argument must be a compile-time constant.

```c
#include "accel.h"

void submit_buffer(uint32_t *buffer, uint32_t count)
{
    picorv32_accel_submit(0, buffer, count);
}

struct accelerator_job {
    uint32_t input_addr;
    uint32_t output_addr;
    uint32_t count;
    uint32_t scale;
};

void submit_job(struct accelerator_job *job, uint32_t tag)
{
    picorv32_accel_submit(1, job, tag);
}
```

Commands 0 and 1 above are example software/accelerator conventions; the CPU
forwards every command ID without interpreting it. A descriptor lets you pass
multiple pointers and scalars in one submission. Keep it and its buffers alive
and unchanged until the accelerator signals completion. Alternatively, define
several accelerator commands that load arguments and then start work.

Passing a pointer does not fetch its contents or create a DMA port. Your
accelerator needs its own access to the referenced memory and any required bus
arbitration. Addresses must be in the accelerator's address space. The C helper
includes a compiler memory clobber; it does not flush caches or drain external
write buffers. Your system must make descriptor/input writes visible before
submission and output writes visible before the CPU consumes results. Apply
the ordering/cache operations required by your memory system. The CPU's
instruction ordering alone cannot ensure visibility through external caches
or posted-write bridges.

## Verification

Run `make test_accel`, or directly:

```sh
iverilog -g2012 -s testbench_accel -o testbench_accel.vvp testbench_accel.v picorv32.v
vvp -N testbench_accel.vvp
```

The self-contained test requires no RISC-V toolchain. It checks both register
file port settings, immediate acceptance, 40-cycle backpressure, stable payloads,
successive submissions without duplicates, high-bit pointer/scalar values,
x0 operands, reset while stalled, disabled/invalid encodings, preserved operand
registers, multiplication/division, and a separate external PCPI instruction.
