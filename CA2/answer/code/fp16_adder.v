// ============================================================================
// Module      : fp16_adder  (Step 4.1 - 4.5 of 05_plan.md)
// Project     : HW1 - FP16 FCNN Accelerator for MNIST (IEEE 754 half)
// Description : The single hardware FP16 adder with an internal accumulator
//               register (resource constraint Q3). One add per clock cycle
//               while start_add pulses for 1 cycle.
//               Algorithm (matches numpy.float16 = IEEE 754 RNE):
//                 eff_exp(e) = (e_field == 0 ? 1 : e_field) - 15  [-14..+15]
//                 mag(e)     = e_field ? {1,f} : {0,f}            (11 bit)
//                 d = |effA - effB| ; larger-exponent (or larger-mag when
//                 equal exponents) operand wins the magnitude of the sum
//                 exact 44-bit alignment: bigU = magBig<<33,
//                                         smallU = magSmall<<(33-d)
//                 sumU = bigU +/- smallU (same sign -> add, else subtract)
//                 normalize sumU to 11-bit sig with MSB at q:
//                   hidden_exp = effBig - 43 + q
//                   frac/g/rs from bits below the 11-bit window, RNE:
//                   inc = g & (r | s | frac[0]) ; carry -> hidden_exp + 1
//                 E_raw = hidden_exp + 15
//                 E_raw >= 31 -> inf ; [1,30] -> normal ;
//                 E_raw <= 0 -> subnormal: RNE of {sig,g,r,s} >> (1 - E_raw + 3)
//               Corners: +/-0 (IEEE sign rules), exact cancellation -> +0,
//               subnormal operands (eff exp 1), overflow -> inf.
//               add_bias is a documentation-compatibility port; operand
//               multiplexing (ping-pong data vs bias ROM) is done in the
//               datapath, so the adder sees a single operand_b stream.
// ============================================================================
`timescale 1ns/1ps

module fp16_adder (
    input  wire        clk,
    input  wire        rst,
    input  wire        clr_accum,    // synchronous clear, priority over start
    input  wire        start_add,    // 1-cycle pulse: accum <= accum + operand_b
    input  wire [15:0] operand_b,
    input  wire        add_bias,     // selector documented in 02 (unused here)
    output wire [15:0] accum_out,
    output reg         add_done      // 1-cycle pulse registered with the sum
);

    reg [15:0] accum_r;
    assign accum_out = accum_r;

    // ---------------- Step 4.1: unpack ----------------
    wire [15:0] A = accum_r;
    wire [15:0] B = operand_b;

    wire        sa = A[15], sb = B[15];
    wire [4:0]  ea = A[14:10], eb = B[14:10];
    wire [9:0]  fa = A[9:0],  fb = B[9:0];
    wire        a_zero = (A[14:0] == 15'h0000);
    wire        b_zero = (B[14:0] == 15'h0000);

    // effective exponents: subnormal carries exponent 1 (2^-14 scale)
    wire [4:0] ea_eff = (ea == 5'd0) ? 5'd1 : ea;
    wire [4:0] eb_eff = (eb == 5'd0) ? 5'd1 : eb;
    wire signed [6:0] eAf = $signed({2'b0, ea_eff}) - 7'sd15;   // -14 .. +15
    wire signed [6:0] eBf = $signed({2'b0, eb_eff}) - 7'sd15;

    // significands with hidden bit (11 bit)
    wire [10:0] ma = (ea == 5'd0) ? {1'b0, fa} : {1'b1, fa};
    wire [10:0] mb = (eb == 5'd0) ? {1'b0, fb} : {1'b1, fb};

    // ---------------- Step 4.2: magnitude order ----------------
    wire signed [6:0] diff = eAf - eBf;                        // -29 .. +29
    wire a_big_pos = (diff > 7'sd0) || (diff == 7'sd0 && (ma >= mb));
    wire b_big_pos = (diff < -7'sd0) || (diff == 7'sd0 && (ma < mb));

    wire        s_big   = a_big_pos ? sa : sb;
    wire signed [6:0] e_big_h = a_big_pos ? eAf : eBf;      // signed effective exponent
    wire [10:0] mag_big   = a_big_pos ? ma : mb;
    wire [10:0] mag_small = a_big_pos ? mb : ma;
    wire [6:0]  e_small_h = a_big_pos ? {1'b0, eb_eff} : {1'b0, ea_eff};
    wire        same_sign = (sa == sb);
    wire signed [6:0] d = a_big_pos ? diff : -diff;            // |diff| 0..29

    // ---------------- Step 4.3: exact 44-bit alignment ----------------
    wire [43:0] big_u   = {mag_big, 33'd0};                    // mag big * 2^33
    wire [5:0]  small_sh = 6'd33 - d[5:0];                     // 4..33
    wire [43:0] small_u = mag_small << small_sh;
    wire [44:0] sum_u   = same_sign ? ({1'b0, big_u} + {1'b0, small_u})
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

    // ---------------- Step 4.4a: normalize to 11-bit sig ----------------
    reg [10:0] sig11;
    always @* begin
        if (q >= 6'd10) sig11 = sum_u >> (q - 10);   // MSB -> bit 10
        else            sig11 = sum_u << (10 - q);
    end

    // guard/round/sticky of bits dropped below the 11-bit window
    reg  [9:0] fr0;
    reg        g0, r0, s0;
    integer    bnd;
    always @* begin
        fr0 = sig11[9:0];
        g0  = 1'b0; r0 = 1'b0; s0 = 1'b0;
        if (q >= 6'd11) begin
            g0  = sum_u[q-11];
            r0  = (q >= 6'd12) ? sum_u[q-12] : 1'b0;
            bnd = q - 13;                        // sticky = OR sum_u[q-13 : 0]
            for (i = 0; i < 45; i = i + 1)
                if (i <= bnd) s0 = s0 | sum_u[i];
        end                                      // q <= 10: exactly representable
    end

    // ---------------- Step 4.4b: RNE round + carry ----------------
    wire inc0 = g0 && (r0 || s0 || fr0[0]);
    wire [10:0] fr_n    = {1'b0, fr0} + (inc0 ? 11'd1 : 11'd0);
    wire        f_carry = fr_n[10];

    // hidden exponent (signed 8 bit)
    wire signed [7:0] h_exp = $signed({{1{e_big_h[6]}}, e_big_h})
                            + $signed({2'b0, q}) - 8'sd43;   // effBig-43+q
    wire signed [7:0] h_c   = h_exp + (f_carry ? 8'sd1 : 8'sd0);
    wire signed [7:0] e_raw = h_c + 8'sd15;

    wire ovf   = (e_raw >= 8'sd31);
    wire isnrm = !ovf && (e_raw >= 8'sd1);

    // ---------------- Step 4.5: subnormal destination shift ----------------
    // frac_sub = {sig, g, r, s} >> (sub_sh + 3), RNE at the subnormal LSB
    wire [5:0] sub_sh = 8'sd1 - e_raw;             // 1..43 (e_raw <= 0)
    wire [13:0] c14 = {sig11, g0, r0, s0};
    wire [5:0]  s3  = sub_sh + 6'd3;               // 4..46

    reg [9:0] f2; reg g2, r2, st2; integer ss2, i2;
    always @* begin
        f2  = c14 >> s3;
        g2  = (s3 >= 6'd1 && s3 <= 6'd14) ? c14[s3-1] : 1'b0;
        r2  = (s3 >= 6'd2 && s3 <= 6'd14) ? c14[s3-2] : 1'b0;
        st2 = 1'b0;
        ss2 = s3 - 2;                              // sticky = OR c14[0..s3-3]
        for (i2 = 0; i2 < 14; i2 = i2 + 1)
            if (i2 < ss2) st2 = st2 | c14[i2];
    end
    wire inc2      = g2 && (r2 || st2 || f2[0]);
    wire [10:0]    f2c = {1'b0, f2} + (inc2 ? 11'd1 : 11'd0);
    wire           sub2norm = f2c[10];             // rounds up to min normal

    // ---------------- final packing ----------------
    reg [15:0] res_comb;
    always @* begin
        if (a_zero && b_zero)
            res_comb = (sa && sb) ? 16'h8000 : 16'h0000;    // (-0)+(-0) = -0
        else if (a_zero)
            res_comb = B;
        else if (b_zero)
            res_comb = A;
        else if (sum_zero)
            res_comb = 16'h0000;                            // exact cancel -> +0
        else if (ovf)
            res_comb = {s_big, 5'h1F, 10'h000};
        else if (isnrm)
            res_comb = {s_big, e_raw[4:0], fr_n[9:0]};
        else if (sub2norm)
            res_comb = {s_big, 5'b00001, 10'h000};
        else
            res_comb = {s_big, 5'h0, f2c[9:0]};
    end

    // ---------------- accumulator register ----------------
    always @(posedge clk) begin
        if (rst) begin
            accum_r <= 16'h0000;
            add_done <= 1'b0;
        end else begin
            add_done <= start_add;
            if (clr_accum)      accum_r <= 16'h0000;
            else if (start_add) accum_r <= res_comb;
        end
    end

endmodule
