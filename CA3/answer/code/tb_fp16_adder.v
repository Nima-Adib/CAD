// ============================================================================
// Testbench : tb_fp16_adder   (CA2 - Phase 1, truncating FP16 adder)
// Run from the project root (the folder containing answer/ assets/ Makefile):
//   vlog -sv answer/code/fp16_adder.v answer/code/tb_fp16_adder.v
//   vsim -c tb_fp16_adder -do "run -all; quit -f"
// Sections:
//   1. Directed tests (CA2 special-case rules, truncation, overflow/underflow)
//   2. Accumulator / control-signal tests (clr priority, hold, add_done)
//   3. Random+corner vectors from answer/code/sim/vec_add_ab.mem / vec_add_exp.mem
//      (produced by gen_vec_add_ca2.py)
// ============================================================================
`timescale 1ns/1ps

module tb_fp16_adder;

    localparam integer NMAX = 65536;

    reg         clk = 1'b0, rst;
    reg         clr_accum, start_add;
    reg  [15:0] operand_b;
    wire [15:0] accum_out;
    wire        add_done;

    always #5 clk = ~clk;

    fp16_adder dut (
        .clk(clk), .rst(rst),
        .clr_accum(clr_accum), .start_add(start_add),
        .operand_b(operand_b), .add_bias(1'b0),
        .accum_out(accum_out), .add_done(add_done)
    );

    integer errors, total;

    // -------- helpers --------
    // clear the accumulator (1 cycle)
    task do_clear;
        begin
            @(negedge clk);
            clr_accum <= 1'b1; start_add <= 1'b0;
            @(negedge clk);
            clr_accum <= 1'b0;
        end
    endtask

    // accum <= accum + b  (1 cycle); result visible right after the posedge
    task do_add(input [15:0] b);
        begin
            @(negedge clk);
            operand_b <= b; start_add <= 1'b1; clr_accum <= 1'b0;
            @(posedge clk); #1;
            start_add <= 1'b0;
        end
    endtask

    task check(input [15:0] got, input [15:0] expv, input [15:0] a, input [15:0] b,
               input [255:0] name);
        begin
            total = total + 1;
            if (got !== expv) begin
                errors = errors + 1;
                if (errors <= 40)
                $display("MISMATCH [%0s] a=%h b=%h exp=%h got=%h", name, a, b, expv, got);
            end
        end
    endtask

    // clear, add a (accum = a), add b, compare with expected
    task pair(input [15:0] a, input [15:0] b, input [15:0] expv, input [255:0] name);
        begin
            do_clear;
            do_add(a);
            do_add(b);
            check(accum_out, expv, a, b, name);
        end
    endtask

    // -------- vector memories --------
    reg [15:0] vecab  [0:NMAX-1];
    reg [15:0] vecexp [0:NMAX/2-1];
    integer i, NV;

    initial begin
        errors = 0; total = 0;
        rst = 1'b1; clr_accum = 1'b0; start_add = 1'b0; operand_b = 16'h0000;
        #22 rst = 1'b0;

        // ===================== 1. directed =====================
        $display("--- directed tests ---");
        pair(16'h3E00, 16'h3E00, 16'h4200, "1.5+1.5=3");
        pair(16'h3C01, 16'h3C01, 16'h4001, "carry -> exp+1");
        pair(16'h3E00, 16'hBC01, 16'h37FC, "sub, normalize left");
        pair(16'h3E00, 16'hBE00, 16'h0000, "exact cancel -> +0");
        pair(16'h4200, 16'h3E00, 16'h4480, "3.0+1.5=4.5");
        pair(16'h3FFF, 16'h13FF, 16'h3FFF, "truncate (RNE would round up)");
        pair(16'h7BFF, 16'hBC01, 16'h7BFE, "truncate on subtract");
        pair(16'h3C01, 16'h2401, 16'h3C11, "different exponents");
        pair(16'h3C01, 16'hB801, 16'h3801, "sub, diff exp 1");
        // special cases of the CA2 statement
        pair(16'h0200, 16'h3E00, 16'h3E00, "subnormal a -> 0");
        pair(16'h3E00, 16'h0200, 16'h3E00, "subnormal b -> 0");
        pair(16'h3C00, 16'h3E00, 16'h3E00, "a mantissa==0 -> 0");
        pair(16'h3E00, 16'h3C00, 16'h3E00, "b mantissa==0 -> 0");
        pair(16'h0000, 16'h8000, 16'h0000, "0 + -0 = 0");
        pair(16'h0401, 16'h8402, 16'h0000, "underflow -> 0");
        pair(16'h7801, 16'h7801, 16'h7C00, "overflow -> exp31 mant0");
        pair(16'hFBFF, 16'hFBFF, 16'hFC00, "negative overflow");
        pair(16'h7BFF, 16'h7BFF, 16'h7C00, "max+max overflow");
        pair(16'h7C00, 16'h7C00, 16'h7C00, "sat + sat");
        pair(16'h7C00, 16'hFC00, 16'h0000, "sat - sat = 0");
        pair(16'h7C00, 16'h3E00, 16'h7C00, "sat + small");
        pair(16'h7C00, 16'hFBFF, 16'h5000, "sat - max = 32");

        // ===================== 2. accumulator / control =====================
        $display("--- accumulator / control tests ---");
        do_clear;
        check(accum_out, 16'h0000, 0, 0, "clear");
        do_add(16'h3E00); check(accum_out, 16'h3E00, 0, 16'h3E00, "chain 1");
        do_add(16'h3E00); check(accum_out, 16'h4200, 0, 16'h3E00, "chain 2");
        do_add(16'h3E00); check(accum_out, 16'h4480, 0, 16'h3E00, "chain 3");

        // add_done follows start_add by one cycle
        @(negedge clk); operand_b <= 16'h3E00; start_add <= 1'b1;
        @(posedge clk); #1;
        total = total + 1;
        if (add_done !== 1'b1) begin errors = errors + 1; $display("MISMATCH add_done should be 1"); end
        start_add <= 1'b0;
        @(posedge clk); #1;
        total = total + 1;
        if (add_done !== 1'b0) begin errors = errors + 1; $display("MISMATCH add_done should return to 0"); end

        // accum holds when start_add = 0
        begin : hold_test
            reg [15:0] held;
            held = accum_out;
            @(negedge clk); operand_b <= 16'h4000; start_add <= 1'b0;
            @(posedge clk); @(posedge clk); #1;
            check(accum_out, held, 0, 16'h4000, "hold without start_add");
        end

        // clr_accum has priority over start_add
        @(negedge clk); operand_b <= 16'h3E00; start_add <= 1'b1; clr_accum <= 1'b1;
        @(posedge clk); #1;
        start_add <= 1'b0; clr_accum <= 1'b0;
        check(accum_out, 16'h0000, 0, 16'h3E00, "clr priority over start");

        // synchronous reset
        do_add(16'h3E00);
        @(negedge clk); rst <= 1'b1;
        @(posedge clk); #1; rst <= 1'b0;
        check(accum_out, 16'h0000, 0, 0, "reset");

        // ===================== 3. file vectors =====================
        $display("--- file vectors ---");
        for (i = 0; i < NMAX; i = i + 1)   vecab[i]  = 16'hxxxx;
        for (i = 0; i < NMAX/2; i = i + 1) vecexp[i] = 16'hxxxx;
        $readmemh("answer/code/sim/vec_add_ab.mem",  vecab);
        $readmemh("answer/code/sim/vec_add_exp.mem", vecexp);
        NV = 0;
        for (i = 0; i < NMAX/2; i = i + 1)
            if (vecab[i*2] !== 16'hxxxx) NV = i + 1;
        $display("loaded %0d vector pairs", NV);
        if (NV == 0) begin
            errors = errors + 1;
            $display("ERROR: no vectors found (run gen_vec_add_ca2.py and put the .mem files in answer/code/sim/)");
        end
        for (i = 0; i < NV; i = i + 1)
            pair(vecab[i*2], vecab[i*2+1], vecexp[i], "file vec");

        $display("ADDER-TB: checks=%0d errors=%0d", total, errors);
        if (errors == 0) $display("ADDER-TB PASS");
        else             $display("ADDER-TB FAIL");
        $finish;
    end

    initial begin #500000000 $display("TIMEOUT"); $finish; end

endmodule
