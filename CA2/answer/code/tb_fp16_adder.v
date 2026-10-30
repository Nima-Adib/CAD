// ============================================================================
// tb_fp16_adder.v - self-checking testbench for the Actel-cell FP16 adder
//
//   DUT   : fp16_adder        (structural, c1 / s2 cells only)
//   MODEL : fp16_adder_model  (behavioural golden model, fp16_adder_model.v)
//
// Both receive exactly the same stimulus; every output is compared after
// every clock cycle.  gated.txt must exist next to the project and contain 0
// before the run; at the end of the simulation it holds the gate count.
//
// compile order:  modules.v  actel_gates.v  fp16_adder.v  fp16_adder_model.v  tb_fp16_adder.v
// ============================================================================
`timescale 1ns/1ps

module tb_fp16_adder;
    reg         clk, rst, clr_accum, start_add, add_bias;
    reg  [15:0] operand_b;
    wire [15:0] dut_out, ref_out;
    wire        dut_done, ref_done;

    fp16_adder       dut (.clk(clk), .rst(rst), .clr_accum(clr_accum), .start_add(start_add),
                          .operand_b(operand_b), .add_bias(add_bias),
                          .accum_out(dut_out), .add_done(dut_done));

    fp16_adder_model ref0 (.clk(clk), .rst(rst), .clr_accum(clr_accum), .start_add(start_add),
                           .operand_b(operand_b), .add_bias(add_bias),
                           .accum_out(ref_out), .add_done(ref_done));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors;
    integer checks;
    integer k, m, seed;
    reg [15:0] ra, rb;
    reg [4:0]  ea, eb;

    // ------------------------------------------------------------ checker
    // called right after a rising edge (outputs have settled)
    task check;
        input [255:0] tag;
        begin
            checks = checks + 1;
            if (dut_out !== ref_out || dut_done !== ref_done) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("MISMATCH (%0s) operand_b=%h  dut=%h done=%b   model=%h done=%b  @%0t",
                             tag, operand_b, dut_out, dut_done, ref_out, ref_done, $time);
            end
        end
    endtask

    // ------------------------------------------------------------ helpers
    // accum <= 0
    task clear_acc;
        begin
            @(negedge clk);
            clr_accum = 1'b1; start_add = 1'b0;
            @(posedge clk); #1;
            clr_accum = 1'b0;
            check("clear");
        end
    endtask

    // accum <= accum + b
    task add_op;
        input [15:0] b;
        begin
            @(negedge clk);
            operand_b = b; start_add = 1'b1; clr_accum = 1'b0;
            @(posedge clk); #1;
            check("add");
            @(negedge clk);
            start_add = 1'b0;
        end
    endtask

    // accum = a ; accum <= a + b
    task pair;
        input [15:0] a, b;
        begin
            clear_acc;
            add_op(a);
            add_op(b);
        end
    endtask

    // ------------------------------------------------------------ stimulus
    initial begin
        errors = 0; checks = 0; seed = 12345;
        rst = 1'b1; clr_accum = 1'b0; start_add = 1'b0; add_bias = 1'b0; operand_b = 16'h0000;
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        @(negedge clk);

        // ---------------- directed corner cases ----------------
        pair(16'h3C00, 16'h3C00);   // 1 + 1
        pair(16'h3C00, 16'hBC00);   // 1 - 1  -> +0
        pair(16'h3C00, 16'hB3FF);   // heavy cancellation
        pair(16'h3C00, 16'hBBFF);
        pair(16'h4000, 16'hBC01);
        pair(16'h3C00, 16'h9000);   // truncation with a sticky bit
        pair(16'h7BFF, 16'h7BFF);   // overflow -> inf
        pair(16'hFBFF, 16'hFBFF);
        pair(16'h7BFF, 16'h7400);
        pair(16'h0400, 16'h8400);   // smallest normal - itself
        pair(16'h0400, 16'h8401);   // underflow -> 0
        pair(16'h0401, 16'h8400);
        pair(16'h0400, 16'h0400);
        pair(16'h0000, 16'h0000);
        pair(16'h8000, 16'h8000);
        pair(16'h8000, 16'h3C00);
        pair(16'h3C00, 16'h8000);
        pair(16'h0001, 16'h3C00);   // subnormal operand -> 0
        pair(16'h3C00, 16'h03FF);
        pair(16'h7800, 16'h7800);
        pair(16'h7BFF, 16'h3C00);
        pair(16'h7C00, 16'h3C00);   // exponent 31 is treated as a normal number
        pair(16'h3C00, 16'h2400);   // exponent difference 11, 12 ...
        pair(16'h3C00, 16'h2000);
        pair(16'h3C00, 16'hA400);
        pair(16'h3C00, 16'hA000);
        pair(16'h3C00, 16'hA800);
        pair(16'h3C00, 16'h8800);

        // ---------------- hold / clear priority ----------------
        clear_acc;
        add_op(16'h4248);                       // 3.140625
        @(negedge clk); operand_b = 16'h3C00; start_add = 1'b0;
        @(posedge clk); #1; check("hold");      // start_add = 0 -> hold
        @(negedge clk); start_add = 1'b1; clr_accum = 1'b1;
        @(posedge clk); #1; check("clr+start"); // clr_accum has priority
        @(negedge clk); start_add = 1'b0; clr_accum = 1'b0;

        // ---------------- random pairs (all 16-bit patterns) ----------------
        for (k = 0; k < 6000; k = k + 1) begin
            ra = $random(seed);
            rb = $random(seed);
            pair(ra, rb);
        end

        // ---------------- random pairs with close exponents (cancellation / sticky) ----------------
        for (k = 0; k < 8000; k = k + 1) begin
            ra = $random(seed);
            ea = ra[14:10];
            m  = $random(seed);
            eb = ea + (m[2:0] - 3);             // exponent within +-4 of ea
            rb = $random(seed);
            rb[14:10] = eb;
            if (k % 2 == 0) rb[15] = ~ra[15];   // half of them: effective subtraction
            if (ea == 5'd0 || ea == 5'd31) ra[14:10] = 5'd15;
            pair(ra, rb);
        end

        // ---------------- long accumulations (no clear) ----------------
        clear_acc;
        for (k = 0; k < 4000; k = k + 1) begin
            rb = $random(seed);
            rb[14:10] = 5'd8 + rb[13:10] % 5'd10;   // exponents 8..17
            add_op(rb);
        end

        // ---------------- reset in the middle of operation ----------------
        @(negedge clk); rst = 1'b1;
        @(posedge clk); #1;
        rst = 1'b0;
        check("reset");
        @(negedge clk);

        $display("----------------------------------------------");
        $display("checks = %0d   errors = %0d", checks, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $display("----------------------------------------------");
        $finish;
    end
endmodule
