// Debug probe: drive specific pairs into fp16_adder and dump internals.
`timescale 1ns/1ps
module tb_probe;
    reg clk = 1'b0, rst;
    always #5 clk = ~clk;
    reg clr = 0, start = 0;
    reg [15:0] op;
    wire [15:0] acc;
    fp16_adder u (.clk(clk), .rst(rst), .clr_accum(clr), .start_add(start),
                  .operand_b(op), .add_bias(1'b0), .accum_out(acc), .add_done());

    task do_pair(input [15:0] xv, input [15:0] yv);
        begin
            @(negedge clk); clr <= 1'b1; start <= 1'b0; op <= xv;
            @(negedge clk); clr <= 1'b0; start <= 1'b1;
            @(negedge clk); op <= yv;
            @(posedge clk); #1;     // accum = x+y  (registered at this edge)
            $display("  acc=%h | eA_h=%0d eB_h=%0d diff=%0d aBig=%b d=%0d same=%b",
                     acc, u.eAf, u.eBf, u.diff, u.a_big_pos, u.d, u.same_sign);
            $display("  magB=%h magS=%h shS=%0d bigU=%h smallU=%h",
                     u.mag_big, u.mag_small, u.small_sh, u.big_u, u.small_u);
            $display("  sumU=%h q=%0d sig11=%h fr0=%h g=%b r=%b s=%b inc0=%b",
                     u.sum_u, u.q, u.sig11, u.fr0, u.g0, u.r0, u.s0, u.inc0);
            $display("  h_exp=%0d fcarry=%b e_raw=%0d ovf=%b isnrm=%b",
                     u.h_c, u.f_carry, u.e_raw, u.ovf, u.isnrm);
            $display("  sub_sh=%0d s3=%0d f2=%h g2=%b r2=%b st2=%b sub2norm=%b",
                     u.sub_sh, u.s3, u.f2, u.g2, u.r2, u.st2, u.sub2norm);
        end
    endtask

    initial begin
        rst = 1'b1; op = 0; clr = 0; start = 0;
        #12 rst = 1'b0;
        @(negedge clk);
        $display("PAIR1: 788E + 8369 (exp 788E)");
        do_pair(16'h788E, 16'h8369);
        @(negedge clk);
        $display("PAIR2: C37B + 413E (exp BC7A)");
        do_pair(16'hC37B, 16'h413E);
        @(negedge clk);
        $display("PAIR3: 896B + 87F3 (exp 8CB2)");
        do_pair(16'h896B, 16'h87F3);
        $finish;
    end
endmodule
