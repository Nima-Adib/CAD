// ============================================================================
// fp16_adder_model : behavioural golden model used by tb_fp16_adder.v
// (the Project-1 adder, adapted to the phase-1 rules: subnormal inputs = 0,
//  underflow -> +0, no (-0) result).  NOT part of the synthesized design.
// ============================================================================
`timescale 1ns/1ps

module fp16_adder_model (
    input  wire        clk,
    input  wire        rst,
    input  wire        clr_accum,    // synchronous clear, priority over start
    input  wire        start_add,    // 1-cycle pulse: accum <= accum + operand_b
    input  wire [15:0] operand_b,
    input  wire        add_bias,     // unused (kept for interface compatibility)
    output wire [15:0] accum_out,
    output reg         add_done      // 1-cycle pulse registered with the sum
);

    reg [15:0] accum_r;
    assign accum_out = accum_r;

    // ---------------- unpack ----------------
    wire [15:0] A = accum_r;
    wire [15:0] B = operand_b;

    wire        sa = A[15], sb = B[15];
    wire [4:0]  ea = A[14:10], eb = B[14:10];
    wire [9:0]  fa = A[9:0],  fb = B[9:0];
    wire        a_zero = (ea == 5'd0);          // zero or subnormal -> 0
    wire        b_zero = (eb == 5'd0);

    // effective exponents: subnormal carries exponent 1
    wire [4:0] ea_eff = (ea == 5'd0) ? 5'd1 : ea;
    wire [4:0] eb_eff = (eb == 5'd0) ? 5'd1 : eb;
    wire signed [6:0] eAf = $signed({2'b0, ea_eff}) - 7'sd15;   // -14 .. +15
    wire signed [6:0] eBf = $signed({2'b0, eb_eff}) - 7'sd15;

    // significands with hidden bit (11 bit)
    wire [10:0] ma = a_zero ? 11'd0 : {1'b1, fa};
    wire [10:0] mb = b_zero ? 11'd0 : {1'b1, fb};

    // ---------------- magnitude order ----------------
    wire signed [6:0] diff = eAf - eBf;
    wire a_big_pos = (diff > 7'sd0) || (diff == 7'sd0 && (ma >= mb));

    wire        s_big     = a_big_pos ? sa : sb;
    wire signed [6:0] e_big_h = a_big_pos ? eAf : eBf;
    wire [10:0] mag_big   = a_big_pos ? ma : mb;
    wire [10:0] mag_small = a_big_pos ? mb : ma;
    wire        same_sign = (sa == sb);
    wire signed [6:0] d   = a_big_pos ? diff : -diff;          // 0..29

    // ---------------- exact 44-bit alignment ----------------
    wire [43:0] big_u    = {mag_big, 33'd0};
    wire [5:0]  small_sh = 6'd33 - d[5:0];                     // 4..33
    wire [43:0] small_u  = mag_small << small_sh;
    wire [44:0] sum_u    = same_sign ? ({1'b0, big_u} + {1'b0, small_u})
                                     : ({1'b0, big_u} - {1'b0, small_u});
    wire        sum_zero = (sum_u == 45'd0);

    // MSB position q of sum_u (0..44)
    reg [5:0] q;
    integer   i;
    always @* begin
        q = 6'd0;
        for (i = 44; i >= 0; i = i - 1)
            if (sum_u[i] && (q == 6'd0)) q = i[5:0];
    end

    // ---------------- normalize + TRUNCATE to 11-bit significand ----------------
    reg [10:0] sig11;
    always @* begin
        if (q >= 6'd10) sig11 = sum_u >> (q - 6'd10);   // MSB -> bit 10, low bits dropped
        else            sig11 = sum_u << (6'd10 - q);   // exactly representable
    end

    // biased exponent: effBig - 43 + q + 15
    wire signed [7:0] e_raw = $signed({e_big_h[6], e_big_h}) + $signed({2'b0, q}) - 8'sd28;

    wire ovf   = (e_raw >= 8'sd31);
    wire isnrm = !ovf && (e_raw >= 8'sd1);

    // ---------------- subnormal result (truncated) ----------------
    wire [5:0]  sub_sh   = 8'sd1 - e_raw;          // 1..43 (e_raw <= 0)
    wire [10:0] sub_full = sig11 >> sub_sh;
    wire [9:0]  frac_sub = sub_full[9:0];

    // ---------------- final packing ----------------
    reg [15:0] res_comb;
    always @* begin
        if (sum_zero)
            res_comb = 16'h0000;                            // exact cancel / both zero -> +0
        else if (ovf)
            res_comb = {s_big, 5'h1F, 10'h000};
        else if (isnrm)
            res_comb = {s_big, e_raw[4:0], sig11[9:0]};
        else
            res_comb = 16'h0000;                            // underflow -> +0
    end

    // ---------------- accumulator register ----------------
    always @(posedge clk) begin
        if (rst) begin
            accum_r  <= 16'h0000;
            add_done <= 1'b0;
        end else begin
            add_done <= start_add;
            if (clr_accum)      accum_r <= 16'h0000;
            else if (start_add) accum_r <= res_comb;
        end
    end

endmodule
