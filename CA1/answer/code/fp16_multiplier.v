// ============================================================================
// Module      : fp16_multiplier  (Step 2.1 - 2.6 of 05_plan.md)
// Project     : HW1 - FP16 FCNN Accelerator for MNIST (IEEE 754 half)
// Description : The single hardware FP16 multiplier (resource constraint Q3).
//               Combinational core + registered result => exactly 1 product
//               per clock cycle while valid_in is held for 7 cycles.
//               Algorithm (matches numpy.float16 = IEEE 754 RNE):
//                 value = p * 2^(e_a + e_b - 50), p = m_a * m_b (22 bit)
//                 normalize p so its MSB (position t) is the hidden bit
//                 hidden_exp = t + e_a + e_b - 50
//                 frac = p[t-1 -: 10], guard=p[t-11], round=p[t-12],
//                 sticky = OR p[t-13:0]        (for t < 11 frac is exact)
//                 inc = g & (r | s | frac[0])   ; carry -> hidden_exp + 1
//                 E_out = hidden_exp + 15
//                 E_out >= 31 -> inf ; E_out in [1,30] -> normal
//                 E_out <= 0   -> subnormal: frac_sub = RNE(p * 2^(e_a+e_b-26))
//               Corner cases: +/-0 (signed), subnormal operands, overflow.
// ============================================================================
`timescale 1ns/1ps

module fp16_multiplier (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,     // hold 1 for the 7 cycles of a row burst
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] result,       // Step 2.1: FP16 product
    output reg         valid_out     // 1-cycle pulse registered with result
);

    // ---------------- Step 2.2: unpack fields ----------------
    wire        s_a   = a[15];
    wire        s_b   = b[15];
    wire [4:0]  e_a   = a[14:10];
    wire [4:0]  e_b   = b[14:10];
    wire [9:0]  f_a   = a[9:0];
    wire [9:0]  f_b   = b[9:0];
    wire        a_zero = (a[14:0] == 15'h0000);   // +0 or -0
    wire        b_zero = (b[14:0] == 15'h0000);
    wire        s_res  = s_a ^ s_b;

    // significands with hidden bit (11 bit); subnormal -> no hidden bit
    wire [10:0] m_a = (e_a == 5'd0) ? {1'b0, f_a} : {1'b1, f_a};
    wire [10:0] m_b = (e_b == 5'd0) ? {1'b0, f_b} : {1'b1, f_b};

    // ---------------- Step 2.3: mantissa product ----------------
    wire [21:0] p = m_a * m_b;              // p != 0 guaranteed (both nonzero)

    // ---------------- Step 2.4: normalize ----------------
    // t = MSB position of p (priority encoder, high -> low)
    reg [4:0] t;
    integer   i;
    always @* begin
        t = 5'd0;
        for (i = 21; i >= 0; i = i - 1)
            if (p[i] && (t == 5'd0)) t = i[4:0];
    end

    // hidden_exp = t + e_a' + e_b' - 50   (signed 8 bit, range [-50, +37])
    // e_a' = max(e_a, 1): a subnormal operand carries effective exponent 1
    // (its 0.f value belongs to the 2^-14 scale), not raw field 0.
    wire [4:0] ea_eff = (e_a == 5'd0) ? 5'd1 : e_a;
    wire [4:0] eb_eff = (e_b == 5'd0) ? 5'd1 : e_b;
    wire signed [7:0] e_hidden_raw =
            $signed({3'b0, t}) + $signed({3'b0, ea_eff}) + $signed({3'b0, eb_eff})
          - 8'sd50;

    // frac / guard / round / sticky of the normalized significand
    reg  [9:0] frac0;
    reg        g0, r0, s0;
    integer    bnd;                            // sticky upper bound (signed)
    always @* begin
        g0 = 1'b0; r0 = 1'b0; s0 = 1'b0; frac0 = 10'h0;
        if (t >= 5'd11) begin
            frac0 = p[t-1 -: 10];             // 10 bits below hidden bit
            g0    = p[t-11];                  // first bit below frac
            r0    = (t >= 5'd12) ? p[t-12] : 1'b0;
            s0    = 1'b0;
            bnd   = t - 13;                   // sticky = OR p[t-13 : 0]
            for (i = 0; i < 22; i = i + 1)
                if (i <= bnd) s0 = s0 | p[i];
        end else begin
            // t <= 10 : all bits of p are represented exactly
            frac0 = (p[9:0] & ((10'h001 << t) - 10'h001)) << (10 - t);
            g0 = 1'b0; r0 = 1'b0; s0 = 1'b0;
        end
    end

    // ---------------- Step 2.5: RNE rounding ----------------
    wire inc0 = g0 && (r0 || s0 || frac0[0]);
    wire [10:0] frac_norm = {1'b0, frac0} + (inc0 ? 11'd1 : 11'd0);
    wire        f_carry   = frac_norm[10];
    wire [9:0]  f_final   = frac_norm[9:0];
    wire signed [7:0] e_hidden = e_hidden_raw + (f_carry ? 8'sd1 : 8'sd0);
    wire signed [7:0] e_raw    = e_hidden + 8'sd15;

    wire ovf   = (e_raw >= 8'sd31);           // -> +/- inf
    wire isnrm = (e_raw >= 8'sd1) && !ovf;
    wire issub = (e_raw <= 8'sd0);

    // Step 2.6: subnormal result path
    //   frac_sub_exact = p * 2^(e_a + e_b - 26)
    wire signed [7:0] K = $signed({3'b0, ea_eff}) + $signed({3'b0, eb_eff}) - 8'sd26;
    reg  [5:0]  s2;                            // right shift = -K (1..26)
    reg  [21:0] qsub;
    reg  [9:0]  f2;
    reg         g2, r2, st2;
    integer     bnd2, ss;
    always @* begin
        f2 = 10'h0; g2 = 1'b0; r2 = 1'b0; st2 = 1'b0; qsub = 22'h0; s2 = 6'd0;
        if (K >= 8'sd0) begin
            f2 = p << K[5:0];                  // exact, fits in 10 bits
        end else begin
            s2   = (-K[7:0]);
            qsub = p >> s2;                    // qsub[9:0] is the kept frac
            f2   = qsub[9:0];
            g2   = (s2 >= 6'd1 && s2 <= 6'd22) ? p[s2-1] : 1'b0;
            r2   = (s2 >= 6'd2 && s2 <= 6'd22) ? p[s2-2] : 1'b0;
            st2  = 1'b0;
            ss   = s2 - 2;                     // sticky = OR p[0 .. s2-3]
            for (i = 0; i < 22; i = i + 1)
                if (i < ss) st2 = st2 | p[i];
        end
    end
    wire inc2    = g2 && (r2 || st2 || f2[0]);
    wire [10:0]  f2c = {1'b0, f2} + (inc2 ? 11'd1 : 11'd0);
    wire         sub2norm = f2c[10];           // rounded up to min normal
    wire [9:0]   f2fin    = f2c[9:0];

    // ---------------- final packing ----------------
    reg [15:0] res_comb;
    always @* begin
        if (a_zero || b_zero)
            res_comb = {s_res, 15'h0000};                       // signed zero
        else if (ovf)
            res_comb = {s_res, 5'h1F, 10'h000};                 // +/- inf
        else if (isnrm)
            res_comb = {s_res, e_raw[4:0], f_final};            // normal
        else if (sub2norm)
            res_comb = {s_res, 5'b00001, 10'h000};              // min normal
        else
            res_comb = {s_res, 5'h0, f2fin};                    // subnormal
    end

    // ---------------- registered output ----------------
    always @(posedge clk) begin
        if (rst) begin
            result    <= 16'h0000;
            valid_out <= 1'b0;
        end else begin
            result    <= res_comb;
            valid_out <= valid_in;
        end
    end

endmodule
