// ============================================================================
// Module      : fp16_multiplier  (TRUNCATE version)
// Project     : FP16 FCNN Accelerator for MNIST (IEEE 754 half)
// Description : The single hardware FP16 multiplier. Combinational core +
//               registered result => one product per clock cycle.
//               Interface is IDENTICAL to the previous (rounding) version.
//
//               Difference from the previous project: NO rounding.
//               The exact product is TRUNCATED (round toward zero): the
//               mantissa bits below the 10-bit fraction are simply dropped.
//               => no guard / round / sticky logic, no increment, no carry.
//
//               Algorithm:
//                 value = p * 2^(e_a + e_b - 50), p = m_a * m_b (22 bit)
//                 t     = MSB position of p (hidden bit)
//                 frac  = the 10 bits just below p[t]   (truncated)
//                 E_raw = t + e_a + e_b - 35
//                 E_raw >= 31 -> inf ; [1,30] -> normal ; <= 0 -> subnormal
//                 subnormal frac = (p * 2^(e_a+e_b-26)) truncated to integer
//               Corners: +/-0 (signed), subnormal operands, overflow -> inf.
// ============================================================================
`timescale 1ns/1ps

module fp16_multiplier (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] result,
    output reg         valid_out
);

    // ---------------- unpack ----------------
    wire        s_a   = a[15];
    wire        s_b   = b[15];
    wire [4:0]  e_a   = a[14:10];
    wire [4:0]  e_b   = b[14:10];
    wire [9:0]  f_a   = a[9:0];
    wire [9:0]  f_b   = b[9:0];
    wire        a_zero = (a[14:0] == 15'h0000);
    wire        b_zero = (b[14:0] == 15'h0000);
    wire        s_res  = s_a ^ s_b;

    // significands with hidden bit (subnormal -> no hidden bit)
    wire [10:0] m_a = (e_a == 5'd0) ? {1'b0, f_a} : {1'b1, f_a};
    wire [10:0] m_b = (e_b == 5'd0) ? {1'b0, f_b} : {1'b1, f_b};

    // ---------------- mantissa product ----------------
    wire [21:0] p = m_a * m_b;

    // ---------------- normalize: t = MSB position of p ----------------
    reg [4:0] t;
    integer   i;
    always @* begin
        t = 5'd0;
        for (i = 21; i >= 0; i = i - 1)
            if (p[i] && (t == 5'd0)) t = i[4:0];
    end

    // effective exponents (subnormal operand -> exponent 1)
    wire [4:0] ea_eff = (e_a == 5'd0) ? 5'd1 : e_a;
    wire [4:0] eb_eff = (e_b == 5'd0) ? 5'd1 : e_b;

    // biased result exponent: t + ea + eb - 50 + 15   (range -33 .. +46)
    wire signed [7:0] e_raw = $signed({3'b0, t}) + $signed({3'b0, ea_eff})
                            + $signed({3'b0, eb_eff}) - 8'sd35;

    wire ovf   = (e_raw >= 8'sd31);
    wire isnrm = (e_raw >= 8'sd1) && !ovf;

    // ---------------- truncated fraction (normal result) ----------------
    // Bring the MSB of p to bit 10 and keep bits [9:0]; lower bits dropped.
    reg [31:0] norm;
    always @* begin
        if (t >= 5'd10) norm = p >> (t - 5'd10);
        else            norm = p << (5'd10 - t);
    end
    wire [9:0] frac = norm[9:0];

    // ---------------- truncated fraction (subnormal result) ----------------
    // frac_sub = floor( p * 2^(ea + eb - 26) )
    wire signed [7:0] K    = $signed({3'b0, ea_eff}) + $signed({3'b0, eb_eff}) - 8'sd26;
    wire signed [7:0] negK = -K;
    reg  [31:0] sub_full;
    always @* begin
        if (K >= 8'sd0) sub_full = p << K[5:0];
        else            sub_full = p >> negK[5:0];
    end
    wire [9:0] frac_sub = sub_full[9:0];

    // ---------------- final packing ----------------
    reg [15:0] res_comb;
    always @* begin
        if (a_zero || b_zero)
            res_comb = {s_res, 15'h0000};               // signed zero
        else if (ovf)
            res_comb = {s_res, 5'h1F, 10'h000};         // +/- inf
        else if (isnrm)
            res_comb = {s_res, e_raw[4:0], frac};       // normal
        else
            res_comb = {s_res, 5'h00, frac_sub};        // subnormal
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
