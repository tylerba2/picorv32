`timescale 1 ns / 1 ps

// Buffered INT8 GEMM, one output row and MAX_N parallel MAC lanes.
// Native memory transfers complete only on mem_valid && mem_ready.
module npu_gemm #(
    parameter integer MAX_M = 16, MAX_N = 16, MAX_K = 64
) (
    input clk, resetn,
    input accel_valid,
    output accel_ready,
    input [6:0] accel_cmd,
    input [31:0] accel_arg0, accel_arg1,
    output busy,
    output reg done,
    output reg [7:0] error,
    output reg [31:0] tag,
    output reg mem_valid,
    input mem_ready,
    output reg [31:0] mem_addr, mem_wdata,
    output reg [3:0] mem_wstrb,
    input [31:0] mem_rdata
);
    localparam IDLE=0, DESC=1, CHECK=2, LOAD_A=3, LOAD_B=4,
               INIT_ROW=5, READ_C=6, MAC=7, STORE_C=8, FINISH=9;
    reg [3:0] state;
    reg [31:0] descriptor, d[0:7];
    wire [31:0] a_base=d[0], b_base=d[1], c_base=d[2];
    wire [31:0] m=d[3], n=d[4], k=d[5];
    wire [31:0] a_count=m*k, b_count=k*n, c_count=m*n;
    wire [32:0] a_end={1'b0,a_base}+(({1'b0,a_count}+33'd3) & 33'h1fffffffc);
    wire [32:0] b_end={1'b0,b_base}+(({1'b0,b_count}+33'd3) & 33'h1fffffffc);
    wire [32:0] c_end={1'b0,c_base}+({1'b0,c_count} << 2);
    reg [31:0] index, row, col, depth;
    reg [31:0] a_offset, b_offset, c_row_addr;
    // Pad storage to a whole DMA word. Unused tail bytes are never computed.
    reg signed [7:0] a_buf[0:((MAX_M*MAX_K+3)/4)*4-1];
    reg signed [7:0] b_buf[0:((MAX_K*MAX_N+3)/4)*4-1];
    reg signed [31:0] sums[0:MAX_N-1];
    wire signed [7:0] a_value = a_buf[a_offset];
    genvar lane;
    wire signed [15:0] product[0:MAX_N-1];
    generate for (lane=0; lane<MAX_N; lane=lane+1) begin: lanes
        wire signed [7:0] b_value = b_buf[b_offset+lane];
        assign product[lane] = a_value * b_value;
    end endgenerate
    assign busy = state != IDLE;
    assign accel_ready = resetn && !busy;

    always @* begin
        mem_valid = 0;
        mem_addr = 0;
        mem_wdata = 0;
        mem_wstrb = 0;
        if (resetn) case (state)
            DESC: begin mem_valid=1; mem_addr=descriptor+(index<<2); end
            LOAD_A: begin mem_valid=1; mem_addr=a_base+index; end
            LOAD_B: begin mem_valid=1; mem_addr=b_base+index; end
            READ_C: begin mem_valid=1; mem_addr=c_row_addr+(col<<2); end
            STORE_C: begin
                mem_valid=1; mem_addr=c_row_addr+(col<<2);
                mem_wdata=sums[col]; mem_wstrb=4'b1111;
            end
            default: begin end
        endcase
    end

    integer i;
    always @(posedge clk) begin
        if (!resetn) begin
            state <= IDLE;
            done <= 0;
            error <= 0;
            tag <= 0;
            descriptor <= 0;
            index <= 0; row <= 0; col <= 0; depth <= 0;
            a_offset <= 0; b_offset <= 0; c_row_addr <= 0;
        end else case (state)
            IDLE: if (accel_valid && accel_ready) begin
                // WAIT (1) is an idle barrier and preserves completion status.
                if (accel_cmd != 1) begin
                    done <= 0; error <= 0; tag <= accel_arg1;
                    if (accel_cmd != 0) begin
                        error <= 1; state <= FINISH;
                    end else if (accel_arg0[1:0] != 0 || accel_arg0 > 32'hffffffe0) begin
                        error <= 2; state <= FINISH;
                    end else begin
                        descriptor <= accel_arg0; index <= 0; state <= DESC;
                    end
                end
            end
            DESC: if (mem_ready) begin
                d[index] <= mem_rdata;
                if (index == 7) state <= CHECK;
                else index <= index+1;
            end
            CHECK: begin
                if (m == 0 || m > MAX_M || n == 0 || n > MAX_N || k == 0 || k > MAX_K) begin
                    error <= 3; state <= FINISH;
                end else if (d[6] > 1 || d[7] != 0) begin
                    error <= 4; state <= FINISH;
                end else if (a_base[1:0] != 0 || b_base[1:0] != 0 || c_base[1:0] != 0) begin
                    error <= 2; state <= FINISH;
                end else if (a_end > 33'h100000000 || b_end > 33'h100000000 || c_end > 33'h100000000) begin
                    error <= 5; state <= FINISH;
                end else begin index <= 0; state <= LOAD_A; end
            end
            LOAD_A: if (mem_ready) begin
                for (i=0; i<4; i=i+1) a_buf[index+i] <= mem_rdata[8*i +: 8];
                if (index+4 >= a_count) begin index <= 0; state <= LOAD_B; end
                else index <= index+4;
            end
            LOAD_B: if (mem_ready) begin
                for (i=0; i<4; i=i+1) b_buf[index+i] <= mem_rdata[8*i +: 8];
                if (index+4 >= b_count) begin
                    row <= 0; a_offset <= 0; c_row_addr <= c_base; state <= INIT_ROW;
                end
                else index <= index+4;
            end
            INIT_ROW: begin
                for (i=0; i<MAX_N; i=i+1) sums[i] <= 0;
                col <= 0; depth <= 0; b_offset <= 0;
                state <= d[6][0] ? READ_C : MAC;
            end
            READ_C: if (mem_ready) begin
                sums[col] <= mem_rdata;
                if (col+1 == n) begin col <= 0; state <= MAC; end
                else col <= col+1;
            end
            MAC: begin
                a_offset <= a_offset+1;
                b_offset <= b_offset+n;
                for (i=0; i<MAX_N; i=i+1)
                    if (i < n) sums[i] <= sums[i] + {{16{product[i][15]}},product[i]};
                if (depth+1 == k) begin col <= 0; state <= STORE_C; end
                else depth <= depth+1;
            end
            STORE_C: if (mem_ready) begin
                if (col+1 == n) begin
                    if (row+1 == m) state <= FINISH;
                    else begin row <= row+1; c_row_addr <= c_row_addr+(n<<2); state <= INIT_ROW; end
                end else col <= col+1;
            end
            FINISH: begin done <= 1; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end
endmodule
