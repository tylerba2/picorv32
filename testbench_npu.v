`timescale 1 ns / 1 ps
module testbench_npu;
    wire [3:0] finished;
    npu_test_case #(.MM(3),.NN(5),.KK(7)) compact_case(finished[0]);
    npu_test_case #(.MM(16),.NN(16),.KK(64)) fullsize(finished[1]);
    npu_cpu_test integrated(finished[2]);
    npu_test_case #(.MM(3),.NN(5),.KK(7),.PERIOD(1)) immediate_case(finished[3]);
    initial begin
        wait (&finished);
        $display("PASS: GEMM reference tests, errors, reset, backpressure, and PicoRV32 integration");
        $finish;
    end
    initial begin #10000000; $fatal(1,"NPU timeout"); end
endmodule

module npu_test_case #(parameter MM=3, NN=5, KK=7, PERIOD=7)(output reg finished=0);
    reg clk=0, resetn=0;
    always #5 clk=!clk;
    reg valid=0;
    reg [6:0] cmd=0;
    reg [31:0] arg0=0, arg1=0;
    wire ready, busy, done, mv;
    wire [7:0] error;
    wire [31:0] tag, ma, mw;
    wire [3:0] ms;
    reg [7:0] ram[0:65535];
    integer cycle=0, writes=0, reads=0, accepted=0;
    wire mr=mv && cycle%PERIOD==0;
    wire [31:0] md=mv ? {ram[ma+3],ram[ma+2],ram[ma+1],ram[ma]} : 32'b0;
    npu_gemm #(.MAX_M(MM),.MAX_N(NN),.MAX_K(KK)) dut (
        .clk(clk),.resetn(resetn),.accel_valid(valid),.accel_ready(ready),
        .accel_cmd(cmd),.accel_arg0(arg0),.accel_arg1(arg1),
        .busy(busy),.done(done),.error(error),.tag(tag),
        .mem_valid(mv),.mem_ready(mr),.mem_addr(ma),.mem_wdata(mw),.mem_wstrb(ms),.mem_rdata(md)
    );
    reg stalled=0;
    reg [67:0] held;
    integer byte_lane;
    always @(posedge clk) begin
        cycle <= cycle+1;
        if (!resetn) stalled <= 0;
        else begin
            if (stalled && {mv,ma,mw,ms} !== {1'b1,held}) $fatal(1,"DMA changed while stalled");
            stalled <= mv && !mr;
            held <= {ma,mw,ms};
            if (valid && ready) accepted <= accepted+1;
            if (mv && mr) begin
                if (ma > 65532 || ma[1:0] != 0) $fatal(1,"Bad DMA address %h",ma);
                if (ms != 0) writes <= writes+1; else reads <= reads+1;
                for (byte_lane=0;byte_lane<4;byte_lane=byte_lane+1)
                    if(ms[byte_lane]) ram[ma+byte_lane] <= mw[8*byte_lane +: 8];
            end
        end
    end
    task putword(input integer addr,input [31:0] value);
        begin {ram[addr+3],ram[addr+2],ram[addr+1],ram[addr]}=value; end
    endtask
    function [31:0] word(input integer addr);
        word={ram[addr+3],ram[addr+2],ram[addr+1],ram[addr]};
    endfunction
    task submit(input [6:0] op,input [31:0] pointer,input [31:0] jobtag);
        begin
            @(negedge clk); valid=1; cmd=op; arg0=pointer; arg1=jobtag;
            @(posedge clk); while(!ready) @(posedge clk);
            @(negedge clk); valid=0;
        end
    endtask
    task descriptor(input integer m,input integer n,input integer k,input integer flags);
        begin
            putword(256,4096); putword(260,16384); putword(264,32768);
            putword(268,m); putword(272,n); putword(276,k); putword(280,flags); putword(284,0);
        end
    endtask
    integer aa[0:MM*KK-1], bb[0:KK*NN-1];
    reg [31:0] expected[0:MM*NN-1];
    integer r,c,t,i,seed=173,job=0;
    task run_job(input integer m,input integer n,input integer k,input integer accumulate,input integer extrema);
        integer before_accepted;
        begin
            descriptor(m,n,k,accumulate);
            for(i=0;i<m*k;i=i+1) begin
                aa[i]=extrema ? (i%2 ? 127 : -128) : ($random(seed)%128);
                ram[4096+i]=aa[i];
            end
            for(i=0;i<k*n;i=i+1) begin
                bb[i]=extrema ? (i%3 ? -128 : 127) : ($random(seed)%128);
                ram[16384+i]=bb[i];
            end
            putword(32764,32'h12345678); putword(32768+4*m*n,32'habcdef01);
            for(r=0;r<m;r=r+1) for(c=0;c<n;c=c+1) begin
                expected[r*n+c]=accumulate ? 32'h7ffffff0+r*n+c : 0;
                putword(32768+4*(r*n+c),accumulate ? expected[r*n+c] : 32'hdeadbeef);
                for(t=0;t<k;t=t+1) expected[r*n+c]=expected[r*n+c]+aa[r*k+t]*bb[t*n+c];
            end
            job=job+1;
            before_accepted=accepted;
            submit(0,256,job);
            if (!busy || done) $fatal(1,"Start status wrong");
            // Issue WAIT immediately: it must stay unaccepted throughout work.
            submit(1,0,0);
            if(busy || !done || error || tag != job) $fatal(1,"Completion status wrong");
            if(accepted != before_accepted+2) $fatal(1,"Duplicate/missing command acceptance");
            for(i=0;i<m*n;i=i+1)
                if(word(32768+4*i) !== expected[i])
                    $fatal(1,"GEMM %0dx%0dx%0d index %0d got %h expected %h",m,n,k,i,word(32768+4*i),expected[i]);
            if(word(32764)!==32'h12345678 || word(32768+4*m*n)!==32'habcdef01) $fatal(1,"Output overrun");
        end
    endtask
    integer before_writes, before_reads, q;
    task expect_error(input [6:0] op,input [31:0] pointer,input [7:0] code);
        begin
            before_writes=writes;
            before_reads=reads;
            submit(op,pointer,32'hbad);
            wait(!busy); @(negedge clk);
            if(!done || error!=code || tag!=32'hbad || writes!=before_writes) $fatal(1,"Error handling failed: %0d",code);
            if(reads-before_reads != ((op!=0 || pointer!=256) ? 0 : 8)) $fatal(1,"Invalid descriptor caused matrix reads");
        end
    endtask
    initial begin
        for(i=0;i<65536;i=i+1) ram[i]=0;
        repeat(4) @(negedge clk); resetn=1;
        run_job(1,1,1,0,1);
        run_job(2,3,3,0,0);
        run_job(3,2,5,1,1);
        run_job(MM,NN,KK,0,1);
        run_job(MM,NN,KK,1,0);
        for(q=0;q<12;q=q+1) run_job(1+q%MM,1+(q*3)%NN,1+(q*5)%KK,q%2,0);
        expect_error(127,256,1);
        expect_error(0,257,2);
        expect_error(0,32'hffffffe4,2);
        descriptor(0,1,1,0); expect_error(0,256,3);
        descriptor(MM+1,1,1,0); expect_error(0,256,3);
        descriptor(1,NN+1,1,0); expect_error(0,256,3);
        descriptor(1,1,KK+1,0); expect_error(0,256,3);
        descriptor(1,1,1,2); expect_error(0,256,4);
        descriptor(1,1,1,0); putword(284,1); expect_error(0,256,4);
        descriptor(1,1,1,0); putword(256,4097); expect_error(0,256,2);
        descriptor(2,2,3,0); putword(256,32'hfffffffc); expect_error(0,256,5);
        descriptor(2,2,3,0); putword(260,32'hfffffffc); expect_error(0,256,5);
        descriptor(2,2,3,0); putword(264,32'hfffffffc); expect_error(0,256,5);
        // Reset cancels an outstanding DMA transfer; then a new job must work.
        descriptor(MM,NN,KK,0); submit(0,256,99);
        wait(mv && (!mr || PERIOD==1)); @(negedge clk); resetn=0;
        #1; if(mv || ready) $fatal(1,"Reset did not suppress handshakes");
        repeat(3) @(negedge clk);
        if(busy || done || error || tag) $fatal(1,"Reset status wrong");
        resetn=1;
        run_job(2,2,3,0,0);
        $display("PASS: NPU limits %0dx%0dx%0d, memory period %0d, %0d reference jobs",MM,NN,KK,PERIOD,job);
        finished=1;
    end
endmodule

module npu_cpu_test(output reg finished=0);
    reg clk=0, resetn=0;
    always #5 clk=!clk;
    wire trap,mv,mi,busy,done;
    wire [7:0] error;
    wire [31:0] ma,mw;
    wire [3:0] ms;
    reg [31:0] ram[0:4095];
    integer cycle=0,i,b,commands=0,wait_stalls=0;
    wire mr=mv && cycle%5==0;
    wire [31:0] md=ram[ma[13:2]];
    picorv32_npu #(.MAX_M(3),.MAX_N(5),.MAX_K(7)) dut (
        .clk(clk),.resetn(resetn),.trap(trap),.mem_valid(mv),.mem_instr(mi),
        .mem_ready(mr),.mem_addr(ma),.mem_wdata(mw),.mem_wstrb(ms),.mem_rdata(md),
        .npu_busy(busy),.npu_done(done),.npu_error(error)
    );
    function [31:0] command(input [6:0] op,input [4:0] rs1,input [4:0] rs2);
        command={op,rs2,rs1,3'b0,5'b0,7'h2b};
    endfunction
    reg stalled=0;
    reg [68:0] held;
    always @(posedge clk) begin
        cycle<=cycle+1;
        if(resetn) begin
            if(stalled && {mv,mi,ma,mw,ms} !== {1'b1,held}) $fatal(1,"Arbiter changed stalled request");
            stalled<=mv && !mr; held<={mi,ma,mw,ms};
            if(dut.av && dut.ar) commands<=commands+1;
            if(dut.av && !dut.ar && dut.cmd==1) wait_stalls<=wait_stalls+1;
            if(mv && mr) begin
                if(ma>=16384) $fatal(1,"Unexpected system address %h",ma);
                for(b=0;b<4;b=b+1) if(ms[b]) ram[ma[13:2]][8*b +: 8]<=mw[8*b +: 8];
            end
            if(trap && !finished) begin
                if(commands!=2 || wait_stalls==0 || !done || busy || error) $fatal(1,"CPU/NPU completion failed");
                if(ram[192]!==2 || ram[193]!==77 || ram[194]!==32'd58 || ram[195]!==32'd64 ||
                   ram[196]!==32'd139 || ram[197]!==32'd154) $fatal(1,"CPU result/status readback failed");
                $display("PASS: PicoRV32 submitted GEMM, waited, and read status/results through shared bus");
                finished<=1;
            end
        end
    end
    initial begin
        for(i=0;i<4096;i=i+1) ram[i]=0;
        ram[0]=32'h10000093; // addi x1,x0,256 (descriptor)
        ram[1]=32'h04d00113; // addi x2,x0,77 (tag)
        ram[2]=command(0,1,2);
        ram[3]=32'h40002203; // lw x4,1024(x0): overlaps DMA traffic
        ram[4]=command(1,0,0);
        ram[5]=32'hf00001b7; // lui x3,0xf0000
        ram[6]=32'h0001a203; // lw x4,0(x3): status
        ram[7]=32'h30402023; // sw x4,768(x0)
        ram[8]=32'h0041a203; // lw x4,4(x3): tag
        ram[9]=32'h30402223; // sw x4,772(x0)
        ram[10]=32'h60002203; ram[11]=32'h30402423;
        ram[12]=32'h60402203; ram[13]=32'h30402623;
        ram[14]=32'h60802203; ram[15]=32'h30402823;
        ram[16]=32'h60c02203; ram[17]=32'h30402a23;
        ram[18]=32'h00100073; // ebreak
        ram[64]=1024; ram[65]=1280; ram[66]=1536;
        ram[67]=2; ram[68]=2; ram[69]=3; ram[70]=0; ram[71]=0;
        ram[256]=32'h04030201; ram[257]=32'h00000605;
        ram[320]=32'h0a090807; ram[321]=32'h00000c0b;
        repeat(4) @(negedge clk); resetn=1;
    end
endmodule
