// ============================================================================
// Testbench : tb_fp16_multiplier   (CA2 - Phase 1, truncating FP16 multiplier)
// Sections:
//   1. Directed tests (zeros, subnormals, signs, normalization/carry, truncate, overflow, underflow)
//   2. Protocol / control tests (latency, reset, back-to-back burst, bubble pipeline)
//   3. Systematic boundary sweep across all 32x32 exponent combinations
// ============================================================================
`timescale 1ns/1ps

module tb_fp16_multiplier;

    reg         clk = 1'b0, rst;
    reg         valid_in;
    reg  [15:0] a, b;
    wire [15:0] result;
    wire        valid_out;

    always #5 clk = ~clk;

    fp16_multiplier dut (
        .clk(clk), .rst(rst),
        .valid_in(valid_in),
        .a(a), .b(b),
        .result(result), .valid_out(valid_out)
    );

    initial begin
        $dumpfile("final.vcd");
        $dumpvars(0, tb_fp16_multiplier);
    end

    integer errors, total;

    // -------- helpers --------
    task check(input [15:0] got, input [15:0] expv, input got_v, input exp_v,
               input [15:0] in_a, input [15:0] in_b, input [255:0] name);
        begin
            total = total + 1;
            if (got !== expv || got_v !== exp_v) begin
                errors = errors + 1;
                if (errors <= 40)
                    $display("MISMATCH [%0s] a=%h b=%h exp=%h (v=%b) got=%h (v=%b)",
                             name, in_a, in_b, expv, exp_v, got, got_v);
            end
        end
    endtask

    // single multiplication transaction (1-cycle registered latency)
    task pair(input [15:0] in_a, input [15:0] in_b, input [15:0] expv, input [255:0] name);
        begin
            @(negedge clk);
            a <= in_a; b <= in_b; valid_in <= 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            valid_in <= 1'b0;
            check(result, expv, valid_out, 1'b1, in_a, in_b, name);
        end
    endtask

    // Reference model for sweep tests
    function [15:0] calc_exp;
        input [15:0] x;
        input [15:0] y;
        reg  [4:0]  ex, ey;
        reg  [10:0] mx, my;
        reg  [31:0] p;
        reg         carry;
        reg  [9:0]  frac;
        integer     e_raw;
        reg         sr;
        begin
            sr = x[15] ^ y[15];
            ex = x[14:10];
            ey = y[14:10];
            if ((ex == 5'd0) || (ey == 5'd0)) begin
                calc_exp = {sr, 15'h0000};
            end else begin
                mx    = {1'b1, x[9:0]};
                my    = {1'b1, y[9:0]};
                p     = mx * my;
                carry = p[21];
                frac  = carry ? p[20:11] : p[19:10];
                e_raw = ex + ey - 15 + carry;
                if (e_raw >= 31)     calc_exp = {sr, 5'h1F, 10'h000};
                else if (e_raw <= 0) calc_exp = {sr, 15'h0000};
                else                 calc_exp = {sr, e_raw[4:0], frac};
            end
        end
    endfunction

    integer ea, eb, trial;
    reg [15:0] sa, sb, sexp;

    initial begin
        errors = 0; total = 0;
        rst = 1'b1; valid_in = 1'b0; a = 16'h0000; b = 16'h0000;
        #22 rst = 1'b0;

        // ===================== 1. directed =====================
        $display("--- directed tests ---");
        // Zero & Subnormals (Phase-1 spec: exponent==0 -> zero operand)
        pair(16'h0000, 16'h3C00, 16'h0000, "0 * 1 = 0");
        pair(16'h3C00, 16'h0000, 16'h0000, "1 * 0 = 0");
        pair(16'h8000, 16'h4000, 16'h8000, "-0 * 2 = -0");
        pair(16'h8000, 16'h8000, 16'h0000, "-0 * -0 = +0");
        pair(16'h0001, 16'h3C00, 16'h0000, "subnormal_a -> 0");
        pair(16'h3C00, 16'h03FF, 16'h0000, "subnormal_b -> 0");
        pair(16'h0200, 16'h0155, 16'h0000, "subn * subn -> 0");

        // Basic normal products
        pair(16'h3C00, 16'h3C00, 16'h3C00, "1.0 * 1.0 = 1.0");
        pair(16'h3C00, 16'h4000, 16'h4000, "1.0 * 2.0 = 2.0");
        pair(16'h3800, 16'h3800, 16'h3400, "0.5 * 0.5 = 0.25");
        pair(16'h3E00, 16'h4100, 16'h4380, "1.5 * 2.5 = 3.75");

        // Sign rules
        pair(16'hBE00, 16'h4100, 16'hC380, "-1.5 * 2.5 = -3.75");
        pair(16'hBE00, 16'hC100, 16'h4380, "-1.5 * -2.5 = +3.75");

        // Normalization (carry shifts mantissa right and increments exponent)
        pair(16'h3E00, 16'h3E00, 16'h4080, "1.5 * 1.5 = 2.25 (carry shift)");

        // Truncation (Phase-1 spec drops lower bits, differing from round-to-nearest)
        pair(16'h3C66, 16'h3C66, 16'h3CD6, "1.1^2 truncated");
        pair(16'h3C01, 16'h3E00, 16'h3E01, "truncate (RNE would be 3E02)");

        // Overflow saturation (exp >= 31 -> exp=31, mantissa=0)
        pair(16'h5C00, 16'h5C00, 16'h7C00, "e_raw == 31 exact saturation");
        pair(16'h7BFF, 16'h4000, 16'h7C00, "max_normal * 2 overflow");
        pair(16'h7BFF, 16'h7BFF, 16'h7C00, "max_normal^2 overflow");
        pair(16'hFBFF, 16'h7BFF, 16'hFC00, "-max * max -> neg overflow");

        // Underflow (e_raw <= 0 -> 0)
        pair(16'h0400, 16'h3400, 16'h0000, "e_raw == 0 exact underflow");
        pair(16'h0400, 16'h0400, 16'h0000, "deep underflow");
        pair(16'h0400, 16'h3C00, 16'h0400, "e_raw == 1 min kept normal");

        // ===================== 2. protocol / control =====================
        $display("--- protocol / control tests ---");
        // Reset priority and hold
        @(negedge clk);
        a <= 16'h3C00; b <= 16'h4000; valid_in <= 1'b1; rst <= 1'b1;
        @(posedge clk); #1;
        total = total + 1;
        if (result !== 16'h0000 || valid_out !== 1'b0) begin
            errors = errors + 1;
            $display("MISMATCH [reset hold] result and valid_out must clear on rst");
        end
        @(negedge clk); rst <= 1'b0; valid_in <= 1'b0;
        @(posedge clk); #1;
        total = total + 1;
        if (valid_out !== 1'b0) begin
            errors = errors + 1;
            $display("MISMATCH [reset release] spurious valid_out after rst");
        end

        // Back-to-back streaming burst (3 consecutive products with zero bubble)
        @(negedge clk); a <= 16'h3C00; b <= 16'h3C00; valid_in <= 1'b1; // 1.0 * 1.0 = 1.0
        @(negedge clk); a <= 16'h3C00; b <= 16'h4000; valid_in <= 1'b1; // 1.0 * 2.0 = 2.0
        check(result, 16'h3C00, valid_out, 1'b1, 16'h3C00, 16'h3C00, "burst item 1");
        @(negedge clk); a <= 16'h4000; b <= 16'h4000; valid_in <= 1'b1; // 2.0 * 2.0 = 4.0
        check(result, 16'h4000, valid_out, 1'b1, 16'h3C00, 16'h4000, "burst item 2");
        @(negedge clk); valid_in <= 1'b0;
        check(result, 16'h4400, valid_out, 1'b1, 16'h4000, 16'h4000, "burst item 3");
        @(negedge clk);
        total = total + 1;
        if (valid_out !== 1'b0) begin
            errors = errors + 1;
            $display("MISMATCH [burst tail] valid_out must deassert after stream");
        end

        // ===================== 3. boundary sweep =====================
        $display("--- boundary sweep (all 32x32 exponent pairs) ---");
        for (ea = 0; ea < 32; ea = ea + 1) begin
            for (eb = 0; eb < 32; eb = eb + 1) begin
                sa = (ea << 10) | 10'h200; // mid-mantissa
                sb = (eb << 10) | 10'h200;
                sexp = calc_exp(sa, sb);
                pair(sa, sb, sexp, "exp sweep");
            end
        end

        $display("MULT-TB: checks=%0d errors=%0d", total, errors);
        if (errors == 0) $display("MULT-TB PASS");
        else             $display("MULT-TB FAIL");
        $finish;
    end

    initial begin #500000000 $display("TIMEOUT"); $finish; end

endmodule
