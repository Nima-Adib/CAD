// Unit testbench (sequential): fp16_adder vs numpy golden vectors.
// Protocol per pair: clear accum; add a (from zero, exact); add b; compare.
`timescale 1ns/1ps
module tb_fp16_add_unit;

    localparam integer NMAX = 65536;
    reg clk = 1'b0, rst;
    always #5 clk = ~clk;

    reg  [15:0] vecab  [0:NMAX-1];       // 2 words per line: a, b
    reg  [15:0] vecexp [0:NMAX/2-1];
    integer     NV, i, k, errors;
    reg  [15:0] va, vb, exp_k;
    reg         clr_accum, start_add;

    fp16_adder u ( .clk(clk), .rst(rst),
                   .clr_accum(clr_accum), .start_add(start_add),
                   .operand_b(va), .add_bias(1'b0),
                   .accum_out(vb), .add_done() );

    initial begin
        rst = 1'b1; clr_accum = 0; start_add = 0; va = 0;
        for (i = 0; i < NMAX; i = i + 1) vecab[i] = 16'hxxxx;
        for (i = 0; i < NMAX/2; i = i + 1) vecexp[i] = 16'hxxxx;
        $readmemh("answer/code/sim/vec_add_ab.mem",  vecab);
        $readmemh("answer/code/sim/vec_add_exp.mem", vecexp);
        NV = 0;
        for (i = 0; i < NMAX/2; i = i + 1)
            if (vecab[i*2] !== 16'hxxxx) NV = i + 1;
        $display("ADD-UNIT: loaded %0d pairs", NV);
        #12 rst = 1'b0;
        errors = 0;
        for (k = 0; k < NV; k = k + 1) begin
            @(negedge clk);
            clr_accum <= 1'b1; start_add <= 1'b0; va <= vecab[k*2]; // preload a
            @(negedge clk);
            clr_accum <= 1'b0; start_add <= 1'b1;                   // P2: accum <= 0+a
            @(negedge clk);
            va <= vecab[k*2+1];                                     // addend b
            @(posedge clk); #1;                                     // P3: accum = a+b
            exp_k = vecexp[k];
            if (vb !== exp_k) begin
                errors = errors + 1;
                if (errors <= 40)
                    $display("MISMATCH %0d: a=%h b=%h exp=%h got=%h",
                             k, vecab[k*2], vecab[k*2+1], exp_k, vb);
            end
        end
        $display("ADD-UNIT: vectors=%0d errors=%0d", NV, errors);
        if (errors == 0) $display("ADD-UNIT PASS");
        else             $display("ADD-UNIT FAIL");
        $finish;
    end

    initial begin #200000000 $display("TIMEOUT"); $finish; end

endmodule
