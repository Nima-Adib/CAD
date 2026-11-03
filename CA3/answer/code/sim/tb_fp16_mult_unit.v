// Unit testbench (sequential, easy-to-debug): fp16_multiplier vs numpy golden.
`timescale 1ns/1ps
module tb_fp16_mult_unit;

    localparam integer NMAX = 65536;
    reg clk = 1'b0, rst;
    always #5 clk = ~clk;

    reg  [15:0] vecab  [0:NMAX-1];       // 2 words per line: a, b
    reg  [15:0] vecexp [0:NMAX/2-1];
    integer     NV, i, k, errors;
    reg  [15:0] va, vb, got, exp_k;

    fp16_multiplier u ( .clk(clk), .rst(rst), .valid_in(1'b1),
                        .a(va), .b(vb), .result(got), .valid_out() );

    initial begin
        rst = 1'b1; va = 0; vb = 0;
        for (i = 0; i < NMAX; i = i + 1) vecab[i] = 16'hxxxx;
        for (i = 0; i < NMAX/2; i = i + 1) vecexp[i] = 16'hxxxx;
        $readmemh("answer/code/sim/vec_mult_ab.mem",  vecab);
        $readmemh("answer/code/sim/vec_mult_exp.mem", vecexp);
        NV = 0;
        for (i = 0; i < NMAX/2; i = i + 1)
            if (vecab[i*2] !== 16'hxxxx) NV = i + 1;
        $display("MULT-UNIT: loaded %0d pairs", NV);
        #12 rst = 1'b0;
        errors = 0;
        for (k = 0; k < NV; k = k + 1) begin
            va <= vecab[k*2]; vb <= vecab[k*2+1];
            @(posedge clk); #1;          // result registered at this edge
            exp_k = vecexp[k];
            if (got !== exp_k) begin
                errors = errors + 1;
                if (errors <= 40)
                    $display("MISMATCH %0d: a=%h b=%h exp=%h got=%h",
                             k, va, vb, exp_k, got);
            end
        end
        $display("MULT-UNIT: vectors=%0d errors=%0d", NV, errors);
        if (errors == 0) $display("MULT-UNIT PASS");
        else             $display("MULT-UNIT FAIL");
        $finish;
    end

    initial begin #200000000 $display("TIMEOUT"); $finish; end

endmodule
