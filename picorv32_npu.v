`timescale 1 ns / 1 ps

// Shared native-memory wrapper. External memory must be non-posted and use
// the same clock/reset. A stalled transfer retains its owner until accepted.
module picorv32_npu #(
    parameter integer MAX_M=16, MAX_N=16, MAX_K=64,
    parameter [31:0] STATUS_BASE=32'hf0000000,
    parameter [31:0] PROGADDR_RESET=0, STACKADDR=32'hffffffff
) (
    input clk, resetn,
    output trap,
    output mem_valid, mem_instr,
    input mem_ready,
    output [31:0] mem_addr, mem_wdata,
    output [3:0] mem_wstrb,
    input [31:0] mem_rdata,
    output npu_busy, npu_done,
    output [7:0] npu_error
);
    wire cv, ci, cr, av, ar, dv, dr;
    wire [31:0] ca, cw, cd, arg0, arg1, da, dw, tag;
    wire [3:0] cs, ds;
    wire [6:0] cmd;
    localparam [15:0] CAP_M=MAX_M[15:0], CAP_N=MAX_N[15:0], CAP_K=MAX_K[15:0];
    wire status_select = ca[31:4] == STATUS_BASE[31:4];
    reg [31:0] status_data;
    always @* case (ca[3:2])
        0: status_data = {16'b0,npu_error,6'b0,npu_done,npu_busy};
        1: status_data = tag;
        2: status_data = {16'd0,CAP_M};
        3: status_data = {CAP_K,CAP_N};
    endcase
    picorv32 #(.ENABLE_ACCEL(1), .PROGADDR_RESET(PROGADDR_RESET), .STACKADDR(STACKADDR)) cpu (
        .clk(clk), .resetn(resetn), .trap(trap),
        .mem_valid(cv), .mem_instr(ci), .mem_ready(cr), .mem_addr(ca),
        .mem_wdata(cw), .mem_wstrb(cs), .mem_rdata(cd),
        .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
        .pcpi_wr(1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0), .irq(32'b0),
        .eoi(), .trace_valid(), .trace_data(),
        .accel_valid(av), .accel_ready(ar), .accel_cmd(cmd), .accel_arg0(arg0), .accel_arg1(arg1)
    );
    npu_gemm #(.MAX_M(MAX_M), .MAX_N(MAX_N), .MAX_K(MAX_K)) npu (
        .clk(clk), .resetn(resetn), .accel_valid(av), .accel_ready(ar),
        .accel_cmd(cmd), .accel_arg0(arg0), .accel_arg1(arg1),
        .busy(npu_busy), .done(npu_done), .error(npu_error), .tag(tag),
        .mem_valid(dv), .mem_ready(dr), .mem_addr(da), .mem_wdata(dw),
        .mem_wstrb(ds), .mem_rdata(mem_rdata)
    );
    reg locked, owner, last_owner;
    wire cpu_request = cv && !status_select;
    wire grant_dma = locked ? owner : (dv && (!cpu_request || !last_owner));
    assign mem_valid = resetn && (grant_dma ? dv : cpu_request);
    assign mem_instr = !grant_dma && ci;
    assign mem_addr = grant_dma ? da : ca;
    assign mem_wdata = grant_dma ? dw : cw;
    assign mem_wstrb = grant_dma ? ds : cs;
    assign dr = mem_valid && grant_dma && mem_ready;
    assign cr = resetn && cv && (status_select || (!grant_dma && mem_ready));
    assign cd = status_select ? status_data : mem_rdata;
    always @(posedge clk) begin
        if (!resetn) begin locked <= 0; owner <= 0; last_owner <= 1; end
        else if (mem_valid) begin
            if (mem_ready) begin locked <= 0; last_owner <= grant_dma; end
            else begin locked <= 1; owner <= grant_dma; end
        end
    end
endmodule
