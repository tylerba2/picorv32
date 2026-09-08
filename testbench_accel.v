`timescale 1 ns / 1 ps

module testbench_accel;
    wire [7:0] done;
    accel_test_case #(.ID(0), .M_EXTENSION(0)) t0(done[0]);
    accel_test_case #(.ID(1), .DUALPORT(0)) t1(done[1]);
    accel_test_case #(.ID(2), .EXTERNAL_PCPI(1)) t2(done[2]);
    accel_test_case #(.ID(3), .DUALPORT(0), .EXTERNAL_PCPI(1), .FAST_MUL(1)) t3(done[3]);
    accel_test_case #(.ID(4), .MODE(1), .M_EXTENSION(0)) t4(done[4]);
    accel_test_case #(.ID(5), .MODE(2)) t5(done[5]);
    accel_test_case #(.ID(6), .MODE(3)) t6(done[6]);
    accel_test_case #(.ID(7), .ABORT_REQUEST(1)) t7(done[7]);
    initial begin
        wait (&done);
        $display("PASS: accelerator instruction (8 configurations)");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Accelerator test timed out");
    end
endmodule

module accel_test_case #(
    parameter ID = 0, DUALPORT = 1, EXTERNAL_PCPI = 0, FAST_MUL = 0,
    parameter MODE = 0, ABORT_REQUEST = 0, M_EXTENSION = 1
) (output reg done = 0);
    reg clk = 0;
    always #5 clk = !clk;
    reg resetn = 0;
    reg abort_pending = ABORT_REQUEST;
    wire trap, mem_valid;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0] mem_wstrb;
    reg [31:0] memory [0:255];
    wire [31:0] mem_rdata = memory[mem_addr[9:2]];
    wire accel_valid;
    wire [6:0] accel_cmd;
    wire [31:0] accel_arg0, accel_arg1;
    integer accepted = 0, stalled = 0;
    wire accel_ready = !abort_pending && (accepted != 1 || stalled >= 40);
    wire pcpi_valid;
    wire [31:0] pcpi_insn;
    // A separate PCPI instruction writes x7, proving coexistence.
    wire external_ready = pcpi_valid && pcpi_insn[6:0] == 7'h5b;
    picorv32 #(
        .ENABLE_ACCEL(MODE != 1), .ENABLE_REGS_DUALPORT(DUALPORT),
        .ENABLE_PCPI(EXTERNAL_PCPI), .ENABLE_MUL(M_EXTENSION && !FAST_MUL),
        .ENABLE_FAST_MUL(M_EXTENSION && FAST_MUL), .ENABLE_DIV(M_EXTENSION), .ENABLE_IRQ(1)
    ) dut (
        .clk(clk), .resetn(resetn), .trap(trap),
        .mem_valid(mem_valid), .mem_ready(mem_valid), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .pcpi_valid(pcpi_valid), .pcpi_insn(pcpi_insn),
        .pcpi_wr(external_ready), .pcpi_rd(32'h1234),
        .pcpi_wait(1'b0), .pcpi_ready(external_ready), .irq(32'b0),
        .accel_valid(accel_valid), .accel_ready(accel_ready),
        .accel_cmd(accel_cmd), .accel_arg0(accel_arg0), .accel_arg1(accel_arg1)
    );
    function [31:0] command;
        input [6:0] cmd;
        input [4:0] rs1, rs2;
        begin command = {cmd, rs2, rs1, 3'b000, 5'b00000, 7'h2b}; end
    endfunction
    integer i, b;
    initial begin
        for (i = 0; i < 256; i = i + 1) memory[i] = 0;
        memory[0] = 32'h800000b7; // lui x1, 0x80000
        memory[1] = 32'h10008093; // addi x1, x1, 256
        memory[2] = 32'h02500113; // addi x2, x0, 37
        memory[3] = command(0, 1, 2);
        if (MODE == 2) memory[3] = memory[3] | 32'h80;   // illegal rd
        if (MODE == 3) memory[3] = memory[3] | 32'h1000; // illegal funct3
        memory[4] = 32'h00408093; // addi x1, x1, 4
        memory[5] = 32'hfff00113; // addi x2, x0, -1
        memory[6] = command(127, 1, 2);
        memory[7] = command(5, 0, 0);
        memory[8] = 32'h00600193; // addi x3, x0, 6
        memory[9] = 32'h00700213; // addi x4, x0, 7
        memory[10] = 32'h024182b3; // mul x5, x3, x4
        memory[11] = 32'h0232c333; // div x6, x5, x3
        if (!M_EXTENSION) begin
            memory[10] = 32'h02a00293; // addi x5, x0, 42
            memory[11] = 32'h00700313; // addi x6, x0, 7
        end
        memory[12] = EXTERNAL_PCPI ? 32'h000003db : 32'h00000393;
        memory[13] = 32'h30102023; // sw x1, 768(x0)
        memory[14] = 32'h30202223; // sw x2, 772(x0)
        memory[15] = 32'h30502423; // sw x5, 776(x0)
        memory[16] = 32'h30602623; // sw x6, 780(x0)
        memory[17] = 32'h30702823; // sw x7, 784(x0)
        memory[18] = 32'h00100073; // ebreak: end of test
        repeat (4) @(negedge clk);
        resetn = 1;
        if (ABORT_REQUEST) begin
            wait (accel_valid);
            repeat (3) @(negedge clk);
            resetn = 0;
            #1;
            if (accel_valid !== 0) $fatal(1, "Request visible during reset");
            repeat (3) @(negedge clk);
            abort_pending = 0;
            resetn = 1;
        end
    end
    reg was_stalled = 0;
    reg [70:0] held_request;
    always @(posedge clk) begin
        if (!resetn) begin
            accepted <= 0;
            stalled <= 0;
            was_stalled <= 0;
        end else if (!done) begin
            if (was_stalled && {accel_valid, accel_cmd, accel_arg0, accel_arg1} !== {1'b1, held_request})
                $fatal(1, "Case %0d: request changed under backpressure", ID);
            was_stalled <= accel_valid && !accel_ready;
            held_request <= {accel_cmd, accel_arg0, accel_arg1};
            if (accel_valid && !accel_ready) stalled <= stalled + 1;
            if (accel_valid && accel_ready) begin
                if (MODE != 0) $fatal(1, "Case %0d: invalid instruction accepted", ID);
                case (accepted)
                    0: if ({accel_cmd, accel_arg0, accel_arg1} !== {7'd0, 32'h80000100, 32'd37})
                        $fatal(1, "Case %0d: first command mismatch", ID);
                    1: if ({accel_cmd, accel_arg0, accel_arg1} !== {7'd127, 32'h80000104, 32'hffffffff} || stalled < 40)
                        $fatal(1, "Case %0d: stalled command mismatch", ID);
                    2: if ({accel_cmd, accel_arg0, accel_arg1} !== {7'd5, 32'b0, 32'b0})
                        $fatal(1, "Case %0d: zero operand command mismatch", ID);
                    default: $fatal(1, "Case %0d: duplicate command", ID);
                endcase
                accepted <= accepted + 1;
                stalled <= 0;
            end
            if (mem_valid)
                for (b = 0; b < 4; b = b + 1)
                    if (mem_wstrb[b]) memory[mem_addr[9:2]][8*b +: 8] <= mem_wdata[8*b +: 8];
            if (trap) begin
                if (MODE == 0) begin
                    if (accepted != 3 || memory[192] !== 32'h80000104 || memory[193] !== 32'hffffffff ||
                        memory[194] !== 42 || memory[195] !== 7 || memory[196] !== (EXTERNAL_PCPI ? 32'h1234 : 0))
                        $fatal(1, "Case %0d: premature trap or register/multiply/divide/PCPI corruption", ID);
                end else if (accepted != 0 || dut.reg_pc !== 12)
                    $fatal(1, "Case %0d: expected illegal instruction trap", ID);
                done <= 1;
            end
        end
    end
endmodule
