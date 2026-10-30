// ============================================================================
// 06_2_programmer — تحویل کد نهایی RTL (Task 06 بخش کد)
// فهرست ماژول‌ها به ترتیب وابستگی: شتاب‌دهنده FCNN MNIST در FP16 (784-8-10)
//
// NOTE: منابع اصلی و تفکیک‌شده در پوشه «answer/code/» قرار دارند و همین فایل
// صرفاً منبع تجمیع‌شده‌ای برای ارزیابی است. هر ماژول کامنت برچسب‌دار «Step X.Y»
// «answer/05_plan.md» دارد. تست‌بنچ مستقل (tb_fcnn_top.v)
// جداگانه تولید شده و در این فایل گنجانده نشده است.
//
// ساخت و اجرا:
//   iverilog -g2012 -o sim_fcnn answer/code/*.v
//   vvp sim_fcnn   # (پیش‌نیاز: اجرا از ریشه پروژه برای مسیرهای assets/*.mem)
//
// نتیجه مرجع: PASS — 10/10 لاجیت بیت‌به‌بیت، pred_digit=2، done پس از 6791 سیکل.
//
// سابقه معماری: پس از نسخه اولیه (PASS با 6801 سیکل)، یک پرامپت اصلاحی معماری اعمال
// شد: رجیستر فایل ۱۸ خانه (rf[0..7] لایه اول، rf[8..17] لاجیت‌های لایه دوم)، حذف
// آرایه موقت logit_stage و استیت L2_FINAL، نوشتار مستقیم rf[8+d] از خروجی خام
// جمع‌کننده. همه تست‌ها پس از هر دو معماری PASS شدند (شرح پرامپت و شواهد صحت‌سنجی:
// 04_prompt_before_after.md بخش ۵؛ پیدانوشت‌های 06_3 و 06_4).
// ============================================================================

// ============================ fp16_multiplier.v ============================
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

// ============================ fp16_adder.v ============================
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

// ============================ relu_unit.v ============================
// ============================================================================
// Module      : relu_unit  (Step 3.1 of 05_plan.md)
// Description : ReLU applied to the layer-1 neuron output only (spec Q4):
//               data_out = max(data_in, 0) for IEEE 754 half precision.
//               Combinational: negative (sign bit set) -> +0.
// ============================================================================
`timescale 1ns/1ps

module relu_unit (
    input  wire [15:0] data_in,
    output wire [15:0] data_out
);
    assign data_out = data_in[15] ? 16'h0000 : data_in;
endmodule

// ============================ layer2_regfile.v ============================
// ============================================================================
// Module      : layer2_regfile  (Step 6.1 of 05_plan.md)
// Description : 18 x 16-bit register file (as-built layout):
//                 rf[0..7]  : the 8 layer-1 ReLU activations; they stay put
//                 and are re-read through rd_addr as the layer-2 multiplier
//                 operands for every digit.
//                 rf[8..17] : the 10 layer-2 logits; digit d lands in
//                 rf[8+d], written directly from the raw FP16 adder output.
//                 The write range (8..17) never overlaps the read range
//                 (0..7), so no staging array / deferred transfer needed.
//               Write is synchronous, read (rd_data) is asynchronous, and
//               all_outputs exposes the 10 LOGITS only: digit d at slices
//               [159-16d -: 16] (digit 0 = rf[8] at [159:144]).
//               argmax uses a monotonic key (sign-magnitude linearized) and a
//               strict '>' chain, so equal logits resolve to the lowest index.
// ============================================================================
`timescale 1ns/1ps

module layer2_regfile (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [4:0]  wr_addr,          // 0..7 = L1, 8..17 = L2
    input  wire [15:0] wr_data,
    input  wire [4:0]  rd_addr,          // operand reads target rf[0..7]
    output wire [15:0] rd_data,          // asynchronous read
    output wire [159:0] all_outputs      // {rf[8],rf[9],...}: digit d = [159-16d -: 16]
);

    reg [15:0] rf [0:17];
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 18; i = i + 1) rf[i] <= 16'h0000;
        end else if (wr_en) begin
            rf[wr_addr] <= wr_data;
        end
    end

    assign rd_data     = rf[rd_addr];
    assign all_outputs = {rf[8], rf[9], rf[10], rf[11], rf[12],
                          rf[13], rf[14], rf[15], rf[16], rf[17]};

endmodule

// ============================ ping_pong_buffer.v ============================
// ============================================================================
// Module      : ping_pong_buffer  (Step 3.2 - 3.4 of 05_plan.md)
// Description : Two 7-slot banks of 16-bit entries (one FC row of products).
//               bank_select marks the bank the WRITER is filling; the reader
//               always drains the OTHER bank. swap_req is persistent from the
//               controller; the swap fires exactly when
//               (wr_full && rd_empty) - i.e. the writer barely caught up and
//               the reader completely drained the current read bank.
//               wr_en/rd_en are 1-cycle enables; a beat is dropped silently
//               when the bank is full/empty (the controller guarantees that
//               this never loses valid data: writes are gated by the bank
//               being writable by construction of the drain rate).
//               rd_data is REGISTERED: it shows the entry pointed by rd_ptr
//               in the cycle AFTER the read beat (1-beat-behind read path).
//               rd_empty means "drained" (rd_ptr == 7); after reset the read
//               side starts empty (rd_ptr = 7) so the very first fill fills
//               bank select 0 and the first swap hands it to the reader.
// ============================================================================
`timescale 1ns/1ps

module ping_pong_buffer (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [15:0] wr_data,
    input  wire        rd_en,
    input  wire        swap_req,
    output reg  [15:0] rd_data,
    output wire        wr_full,        // wr_ptr == 7 : writer bank filled
    output wire        rd_empty,       // rd_ptr == 7 : reader bank drained
    output reg         bank_select
);

    reg [15:0] bank0 [0:6];
    reg [15:0] bank1 [0:6];
    reg [2:0]  wr_ptr, rd_ptr;

    assign wr_full  = (wr_ptr == 3'd7);
    assign rd_empty = (rd_ptr == 3'd7);

    wire do_swap = swap_req && wr_full && rd_empty;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr      <= 3'd0;
            rd_ptr      <= 3'd7;          // read side starts empty
            bank_select <= 1'b0;          // first fill goes into bank 0
            rd_data     <= 16'h0000;
        end else if (do_swap) begin
            // Swap with same-cycle transactions preserved (zero-stall):
            // the writer's next product fills slot 0 of the NEW write bank
            // (the just-drained bank) and, if the reader asks, the first
            // entry of the freshly-filled bank is read immediately.
            bank_select <= ~bank_select;
            if (wr_en) begin
                if (bank_select == 1'b0) bank1[3'd0] <= wr_data;   // old read bank
                else                     bank0[3'd0] <= wr_data;
                wr_ptr <= 3'd1;
            end else begin
                wr_ptr <= 3'd0;
            end
            if (rd_en) begin
                if (bank_select == 1'b0) rd_data <= bank0[3'd0];   // old write bank
                else                     rd_data <= bank1[3'd0];
                rd_ptr <= 3'd1;
            end else begin
                rd_ptr <= 3'd0;
            end
        end else begin
            if (wr_en && !wr_full) begin
                if (bank_select == 1'b0) bank0[wr_ptr] <= wr_data;
                else                     bank1[wr_ptr] <= wr_data;
                wr_ptr <= wr_ptr + 3'd1;
            end
            if (rd_en && !rd_empty) begin
                // reader drains the bank opposite to bank_select
                if (bank_select == 1'b0) rd_data <= bank1[rd_ptr];
                else                     rd_data <= bank0[rd_ptr];
                rd_ptr <= rd_ptr + 3'd1;
            end
        end
    end

endmodule

// ============================ sram_weights_model.v ============================
// ============================================================================
// Module      : sram_weights_model  (Step 1.2 / Step 7.x of 05_plan.md)
// Description : Behavioral SRAM model of the weight memory, 7-cycle latency.
//               Contents: 6352 x 16-bit words from assets/weights.mem
//               (6272 weight words = 8 neurons x 784, neuron-major layout,
//                followed by the 80 L2 words: rows 896..915 are W2, padded to
//                7 lanes per row; each L2 neuron takes rows 896+2d (side 0,
//                lanes 0..6 = w2[d][0..6]) and 896+2d+1 (side 1, lane 0 =
//                w2[d][7], lanes 1..6 = 0x0000 padding).
//               Timing (matches 03_spec.md SR table):
//                 read_en high during cycle T
//                   -> data_valid high during cycle T+7
//                   -> data_out registered at the SAME posedge (end of T+6).
//               A new issue is accepted while the old row completes: on the
//               completion edge (cnt==1) with read_en high, the model both
//               delivers data_valid for the old row and starts the countdown
//               for the new one (zero-stall pipelined reads, one in flight).
// ============================================================================
`timescale 1ns/1ps

module sram_weights_model (
    input  wire         clk,
    input  wire         rst,
    input  wire         read_en,
    input  wire [10:0]  addr,           // row 0..915
    output reg  [111:0] data_out,       // 7 lanes, lane 0 on [111:96]
    output reg          data_valid
);

    localparam LATENCY = 3'd6;          // issue -> cnt=6; completes at cnt==1
                                        // => data_valid 7 cycles after issue

    reg [15:0]  mem_flat [0:6351];      // raw file words
    reg [111:0] rows     [0:915];       // unpacked 7-lane rows
    reg [10:0]  lat_addr;
    reg [2:0]   cnt;

    initial begin
        integer w, r, j, d;
        for (w = 0; w < 6352; w = w + 1) mem_flat[w] = 16'h0000;
        $readmemh("assets/weights.mem", mem_flat);
        // ---- L1 rows 0..895: contiguous packing -----------------------------
        // row r = flat[7r .. 7r+7]  (neuron j owns rows 112j .. 112j+111)
        for (r = 0; r < 896; r = r + 1)
            for (j = 0; j < 7; j = j + 1)
                rows[r][111 - 16*j -: 16] = mem_flat[r*7 + j];
        // ---- L2 rows 896..915: per-digit pairing ----------------------------
        // row 896+2d = w2[d][0..6] (side 0, lanes 0..6)
        // row 897+2d = w2[d][7], 0x0000 x6 (side 1, lane 0 only)
        for (d = 0; d < 10; d = d + 1) begin
            for (j = 0; j < 7; j = j + 1)
                rows[896 + 2*d][111 - 16*j -: 16] = mem_flat[6272 + 8*d + j];
            rows[897 + 2*d][111 -: 16] = mem_flat[6272 + 8*d + 7];
            for (j = 1; j < 7; j = j + 1)
                rows[897 + 2*d][111 - 16*j -: 16] = 16'h0000;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            cnt        <= 3'd0;
            lat_addr   <= 11'd0;
            data_out   <= 112'd0;
            data_valid <= 1'b0;
        end else if (read_en) begin
            lat_addr <= addr;
            // a row completing exactly on this edge still delivers its pulse
            if (cnt == 3'd1) begin
                data_out   <= rows[lat_addr];
                data_valid <= 1'b1;
            end else begin
                data_valid <= 1'b0;
            end
            cnt <= LATENCY;             // restart countdown for the new row
        end else if (cnt != 3'd0) begin
            if (cnt == 3'd1) begin
                data_out   <= rows[lat_addr];
                data_valid <= 1'b1;
                cnt        <= 3'd0;
            end else begin
                cnt <= cnt - 3'd1;
            end
        end else begin
            data_valid <= 1'b0;
        end
    end

endmodule

// ============================ sram_inputs_model.v ============================
// ============================================================================
// Module      : sram_inputs_model  (Step 1.2 / Step 7.x of 05_plan.md)
// Description : Behavioral SRAM model of the input activations, 7-cycle
//               latency. Contents: 784 x 16-bit words from assets/input.mem
//               = 112 rows x 7 lanes (the same fixed x for every L1 neuron).
//               Timing identical to sram_weights_model:
//                 read_en high during cycle T -> data_valid high during T+7,
//                 data_out registered at the same posedge; new issues restart
//               the countdown while the current row completes (cnt == 1).
// ============================================================================
`timescale 1ns/1ps

module sram_inputs_model (
    input  wire         clk,
    input  wire         rst,
    input  wire         read_en,
    input  wire [6:0]   addr,           // row 0..111
    output reg  [111:0] data_out,       // 7 lanes, lane 0 on [111:96]
    output reg          data_valid
);

    localparam LATENCY = 3'd6;          // issue -> cnt=6; completes at cnt==1

    reg [15:0]  mem_flat [0:783];
    reg [111:0] rows     [0:111];
    reg [6:0]   lat_addr;
    reg [2:0]   cnt;

    initial begin
        integer w, r, j;
        for (w = 0; w < 784; w = w + 1) mem_flat[w] = 16'h0000;
        $readmemh("assets/input.mem", mem_flat);
        for (r = 0; r < 112; r = r + 1)
            for (j = 0; j < 7; j = j + 1)
                rows[r][111 - 16*j -: 16] = mem_flat[r*7 + j];
    end

    always @(posedge clk) begin
        if (rst) begin
            cnt        <= 3'd0;
            lat_addr   <= 7'd0;
            data_out   <= 112'd0;
            data_valid <= 1'b0;
        end else if (read_en) begin
            lat_addr <= addr;
            if (cnt == 3'd1) begin
                data_out   <= rows[lat_addr];
                data_valid <= 1'b1;
            end else begin
                data_valid <= 1'b0;
            end
            cnt <= LATENCY;
        end else if (cnt != 3'd0) begin
            if (cnt == 3'd1) begin
                data_out   <= rows[lat_addr];
                data_valid <= 1'b1;
                cnt        <= 3'd0;
            end else begin
                cnt <= cnt - 3'd1;
            end
        end else begin
            data_valid <= 1'b0;
        end
    end

endmodule

// ============================ fcnn_datapath.v ============================
// ============================================================================
// Module      : fcnn_datapath  (Step 1.1, 2.x, 3.x, 6.x, 8.x of 05_plan.md)
// Project     : HW1 - FP16 FCNN Accelerator for MNIST (IEEE 754 half)
// Description : Integrated datapath: SRAM models + row regs + the single
//               FP16 multiplier + ping-pong buffer + the single FP16 adder
//               (internal accumulator) + ReLU + 18-entry layer-2 regfile
//               (rf[0..7] = L1 activations, rf[8..17] = direct-written
//               logits) + bias ROM + ArgMax.
//
//               Prefetch / zero-stall read engine contract:
//                 - The controller issues one SRAM row read (read_en pulse);
//                   the row arrives 7 cycles later as a 1-cycle data_valid
//                   pulse. On EVERY valid pulse the datapath latches the 7
//                   lanes into w_reg/x_reg, while the controller issues the
//                   next row in the same cycle (back-to-back, one in flight).
//                 - The multiplier consumes w_reg[beat]/x_reg[beat] with
//                   mult_elem_sel = beat; the result registers at the beat
//                   edge and mult_valid pulses the next cycle.
//                 - buf_wr_en (controller RUN window) is windowed 1 cycle
//                   internally so the trailing product of the last beat is
//                   not lost; the ping-pong write occurs when
//                   (mult_valid && wr_win).
//                 - Adder kicks follow ACCEPTED ping-pong reads by 1 beat
//                   (rd_hit delayed): the accumulator sums exactly one term
//                   per drained product, in fill order.
//               Bias add: the controller pulses add_start together with
//               add_bias_sel=1; the adder operand mux switches to bias ROM.
//
//               Write schemes (03_spec.md 2.6, 18-row layout):
//                 l2_wr_en=1 && layer_sel==0 -> rf[l2_wr_addr]     <=
//                    relu(accum)                                  (L1 STORE, rf[0..7])
//                 l2_wr_en=1 && layer_sel==1 -> rf[8+l2_wr_addr]   <=
//                    accum (raw adder output)                     (L2 STAGE, rf[8..17])
//               The two ranges are disjoint: during L2 the multiplier keeps
//               reading h0..h7 from rf[0..7] while each digit's raw result
//               lands in rf[8..17], so a Read-After-Write hazard is
//               structurally impossible and no staging array or
//               deferred transfer exists.
// ============================================================================
`timescale 1ns/1ps

module fcnn_datapath (
    input  wire         clk,
    input  wire         rst,
    // ---- SRAM read side (addresses issued by controller) ----
    input  wire [9:0]   sram_w_addr,
    input  wire         sram_w_read_en,
    input  wire [6:0]   sram_in_addr,
    input  wire         sram_in_read_en,
    output wire         sram_w_valid,
    output wire         sram_in_valid,
    // ---- multiplier / ping-pong control ----
    input  wire         mult_en,
    input  wire [2:0]   mult_elem_sel,
    output wire         mult_valid,
    input  wire         buf_wr_en,
    input  wire         buf_rd_en,
    input  wire         buf_swap,
    output wire         buf_full,
    output wire         buf_empty,
    // ---- adder control ----
    input  wire         add_start,        // 1-cycle pulse (bias adds)
    input  wire         add_bias_sel,
    input  wire         accum_clr,
    output wire         add_done,
    // ---- layer select / bias ----
    input  wire         layer_sel,        // 0: L1 (ReLU on) | 1: L2 (raw)
    input  wire [4:0]   bias_addr,        // 0..7 L1, 8..17 L2
    // ---- register file control ----
    input  wire         l2_wr_en,
    input  wire [3:0]   l2_wr_addr,
    input  wire [3:0]   l2_rd_addr,
    // ---- final outputs ----
    output wire [159:0] logits_out,       // = all_outputs (digit 0 = rf[8] at [159:144])
    output wire [3:0]   pred_digit
);

    // ================= internal signals =================
    wire [111:0]  w_row_data, x_row_data;
    wire [15:0]   w_reg   [0:6];
    wire [15:0]   x_reg   [0:6];    // (reg arrays below; wires for muxing)
    reg  [15:0]   w_regs  [0:6];
    reg  [15:0]   x_regs  [0:6];
    wire [15:0]   rf_rd_data, rf_wr_data;
    wire [159:0]  rf_all;
    wire          rf_wr_en;
    wire [4:0]    rf_wr_addr;
    wire [15:0]   mult_a, mult_b, mult_result;
    wire          pp_bank_sel;
    reg           wr_win;
    wire [15:0]   pp_rd_data;
    wire [15:0]   bias_val, adder_op, accum_q, relu_out;

    // ================= memory models =================
    sram_weights_model u_wmem (.clk(clk), .rst(rst),
        .read_en(sram_w_read_en), .addr({1'b0, sram_w_addr}),
        .data_out(w_row_data), .data_valid(sram_w_valid));
    sram_inputs_model u_imem (.clk(clk), .rst(rst),
        .read_en(sram_in_read_en), .addr(sram_in_addr),
        .data_out(x_row_data), .data_valid(sram_in_valid));

    // ================= row registers =================
    // (unwrapped into reg arrays; w_reg/x_reg wires alias them for muxing)
    integer ii;
    always @(posedge clk) begin
        if (rst) begin
            for (ii = 0; ii < 7; ii = ii + 1) begin
                w_regs[ii] <= 16'h0000;
                x_regs[ii] <= 16'h0000;
            end
        end else begin
            if (sram_w_valid)
                for (ii = 0; ii < 7; ii = ii + 1)
                    w_regs[ii] <= w_row_data[111 - 16*ii -: 16];
            if (sram_in_valid)
                for (ii = 0; ii < 7; ii = ii + 1)
                    x_regs[ii] <= x_row_data[111 - 16*ii -: 16];
        end
    end
    for (genvar gg = 0; gg < 7; gg = gg + 1) begin : alias_rows
        assign w_reg[gg] = w_regs[gg];
        assign x_reg[gg] = x_regs[gg];
    end

    // ================= register file (async read, 18 entries) =================
    layer2_regfile u_rf (.clk(clk), .rst(rst),
        .wr_en(rf_wr_en), .wr_addr(rf_wr_addr), .wr_data(rf_wr_data),
        .rd_addr({1'b0, l2_rd_addr}), .rd_data(rf_rd_data), .all_outputs(rf_all));

    // ================= the single FP16 multiplier =================
    assign mult_a = w_reg[mult_elem_sel];
    assign mult_b = layer_sel ? rf_rd_data : x_reg[mult_elem_sel];
    fp16_multiplier u_mul (.clk(clk), .rst(rst),
        .valid_in(mult_en), .a(mult_a), .b(mult_b),
        .result(mult_result), .valid_out(mult_valid));

    // ================= ping-pong buffer =================
    // 1-cycle write window: keeps the trailing product of the last beat
    always @(posedge clk) begin
        if (rst) wr_win <= 1'b0;
        else     wr_win <= buf_wr_en;
    end
    ping_pong_buffer u_pp (.clk(clk), .rst(rst),
        .wr_en(mult_valid && wr_win), .wr_data(mult_result),
        .rd_en(buf_rd_en), .swap_req(buf_swap),
        .rd_data(pp_rd_data), .wr_full(buf_full),
        .rd_empty(buf_empty), .bank_select(pp_bank_sel));

    // ================= the single FP16 adder (accumulator) =================
    // rd_hit covers BOTH read kinds: a normal drain beat and the swap-cycle
    // read (the swap handover consumes slot 0 of the freshly-filled bank in
    // the same edge - skip it here and that product never reaches the adder).
    wire rd_hit = (buf_rd_en && !buf_empty) ||
                  (buf_swap && buf_full && buf_empty && buf_rd_en);
    reg  rd_hit_d;
    always @(posedge clk) begin
        if (rst) rd_hit_d <= 1'b0;
        else     rd_hit_d <= rd_hit;
    end
    assign adder_op    = add_bias_sel ? bias_val : pp_rd_data;
    wire adder_kick = rd_hit_d || add_start;   // read kicks + bias kick
    fp16_adder u_add (.clk(clk), .rst(rst),
        .clr_accum(accum_clr), .start_add(adder_kick),
        .operand_b(adder_op), .add_bias(add_bias_sel),
        .accum_out(accum_q), .add_done(add_done));

    // ================= ReLU (L1 only) =================
    relu_unit u_relu (.data_in(accum_q), .data_out(relu_out));

    // ================= RF write side (direct, no staging) ============
    // L1 STORE : rf[l2_wr_addr]   <= relu(accum)   (rf[0..7])
    // L2 STAGE : rf[l2_wr_addr+8] <= accum         (rf[8..17], raw)
    // ranges disjoint => L2 operand reads (rf[0..7]) can never race the
    // digit writes, so the adder result goes straight into the regfile.
    assign rf_wr_en   = l2_wr_en;
    assign rf_wr_addr = layer_sel ? ({1'b0, l2_wr_addr} + 5'd8)
                                  : {1'b0, l2_wr_addr};
    assign rf_wr_data = layer_sel ? accum_q : relu_out;

    // ================= bias ROM =================
    reg [15:0] bias_rom [0:17];
    initial $readmemh("assets/bias.mem", bias_rom);
    assign bias_val = bias_rom[bias_addr];

    // ================= outputs =================
    assign logits_out = rf_all;

    // ArgMax over the 10 logits with a monotone key transform:
    //   key = fp[15] ? {1'b0, ~fp[14:0]} : {1'b1, fp[14:0]}
    // (linearizes sign-magnitude order; strict '>' keeps lowest index on ties)
    function [15:0] mono_key;
        input [15:0] v;
        begin
            mono_key = v[15] ? {1'b0, ~v[14:0]} : {1'b1, v[14:0]};
        end
    endfunction

    reg  [3:0]  best_idx;
    reg  [15:0] best_key;
    integer m;
    always @* begin
        best_idx = 4'd0;
        best_key = mono_key(logits_out[159:144]);
        for (m = 1; m < 10; m = m + 1) begin
            if (mono_key(logits_out[(159 - 16*m) -: 16]) > best_key) begin
                best_key = mono_key(logits_out[(159 - 16*m) -: 16]);
                best_idx = m[3:0];
            end
        end
    end
    assign pred_digit = best_idx;

endmodule

// ============================ fcnn_controller.v ============================
// ============================================================================
// Module      : fcnn_controller  (Step 5.1 - 5.8, 7.x of 05_plan.md)
// Project     : HW1 - FP16 FCNN Accelerator for MNIST (IEEE 754 half)
// Description : Main FSM. 15 states covering IDLE, the 8 L1 neuron phases
//               (REQ / WAIT / RUN / TAIL / BIAS / STORE), the 10 L2 digit
//               phases (REQ / WAIT / RUN0 / RUN1 / TAIL / BIAS / STAGE)
//               and DONE. L2 STAGE writes rf[8+d] directly (18-row
//               regfile), so no staged FINAL transfer exists.
//
//               Prefetch / zero-stall issue engine:
//                 - REQ issues SRAM row 0 and pulses accum_clr.
//                 - On EVERY SRAM valid pulse (WAIT or RUN) the next row is
//                   issued in the SAME cycle: issue-on-arrival keeps exactly
//                   one row in flight; L1 row k for neuron j arrives exactly
//                   7 cycles after its issue, i.e. at beat 6 of row k-1.
//                   L1 rows are bounded by batch (0..111); L2 rows alternate
//                   side 0 (rows 896+2d : lanes 0..6) and side 1
//                   (rows 896+2d+1 : lane 0 data, lanes 1..6 zero-padding).
//                 - The last row of a neuron sets last_arr on its arrival;
//                   the FSM leaves RUN exactly 7 beats later (row 111's beat 6).
//                 - TAIL drains the ping-pong buffer's final bank. Exit is
//                   COUNT-BASED: add_cnt counts add_done pulses (1:1 with
//                   completed adds, including every bank's swap-cycle read)
//                   and TAIL releases when the neuron's full term count is
//                   reached (L1: 784 product adds, L2: 14) - phase-robust by
//                   construction, no dependence on buffer flags.
//                 - BIAS is a ONE-cycle state: the adder folds the bias at the
//                   edge that closes it (add_done merely reports the add one
//                   cycle later); STORE/STAGE then latch the final result.
//
//               Timing notes: L1 needs 8 neurons x 7 weight rows x 7 lanes = 784
//               products; SRAM issues use w_addr = 112*j + batch and
//               in_addr = batch. L2 uses w_addr = 896 + 2*d (+ side).
//
//               State encoding (4 bit):
//                 0 IDLE      1 L1_REQ    2 L1_WAIT   3 L1_RUN
//                 4 L1_TAIL   5 L1_BIAS   6 L1_STORE  7 L2_REQ
//                 8 L2_WAIT   9 L2_RUN0  10 L2_RUN1  11 L2_TAIL
//                12 L2_BIAS  13 L2_STAGE 14 DONE
// ============================================================================
`timescale 1ns/1ps

module fcnn_controller (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    // status inputs from datapath
    input  wire        sram_w_valid,
    input  wire        sram_in_valid,
    input  wire        mult_valid,
    input  wire        buf_full,
    input  wire        buf_empty,
    input  wire        add_done,
    // control outputs: memories
    output reg  [9:0]  sram_w_addr,
    output reg         sram_w_read_en,
    output reg  [6:0]  sram_in_addr,
    output reg         sram_in_read_en,
    // control outputs: multiplier / ping-pong
    output reg         mult_en,
    output reg  [2:0]  mult_elem_sel,
    output reg         buf_wr_en,
    output reg         buf_rd_en,
    output reg         buf_swap,
    // control outputs: adder / register file
    output reg         add_start,
    output reg         add_bias_sel,
    output reg         accum_clr,
    output reg         layer_sel,
    output reg  [4:0]  bias_addr,
    output reg         l2_wr_en,
    output reg  [3:0]  l2_wr_addr,
    output reg  [3:0]  l2_rd_addr,
    // status outputs
    output reg         busy,
    output reg         done
);

    // ---------------- state encoding ----------------
    localparam S_IDLE      = 4'd0,
               S_L1_REQ    = 4'd1,
               S_L1_WAIT   = 4'd2,
               S_L1_RUN    = 4'd3,
               S_L1_TAIL   = 4'd4,
               S_L1_BIAS   = 4'd5,
               S_L1_STORE  = 4'd6,
               S_L2_REQ    = 4'd7,
               S_L2_WAIT   = 4'd8,
               S_L2_RUN0   = 4'd9,
               S_L2_RUN1   = 4'd10,
               S_L2_TAIL   = 4'd11,
               S_L2_BIAS   = 4'd12,
               S_L2_STAGE  = 4'd13,
               S_DONE      = 4'd14;

    // ---------------- state / cursor registers ----------------
    reg [3:0]  state;
    reg [2:0]  j;         // L1 neuron 0..7
    reg [3:0]  d;         // L2 digit   0..9
    reg        side;      // L2 weight side (0 : lanes 0..6, 1 : lane 7)
    reg [6:0]  batch;     // row index of the just-latched L1 row (0..112)
    reg [2:0]  beat;      // 0..6 inside a row
    reg        last_arr;  // the last row of the current neuron was latched
    reg [9:0]  add_cnt;   // adder completions since the current neuron's REQ
                          // (L1: 784 products, L2: 14 products)

    wire arr_l1 = sram_w_valid && sram_in_valid;   // L1: both rows complete
    wire arr_l2 = sram_w_valid;                    // L2: weights only

    // ---------------- combinational control outputs ----------------
    always @* begin
        // defaults (no action)
        sram_w_read_en = 1'b0;      sram_w_addr    = 10'd0;
        sram_in_read_en= 1'b0;      sram_in_addr   = 7'd0;
        mult_en        = 1'b0;      mult_elem_sel  = beat;
        buf_wr_en      = 1'b0;      buf_rd_en      = 1'b0;
        buf_swap       = 1'b0;
        add_start      = 1'b0;      add_bias_sel   = 1'b0;
        accum_clr      = 1'b0;
        l2_wr_en       = 1'b0;      l2_wr_addr     = 4'd0;
        l2_rd_addr     = 4'd0;
        bias_addr      = 5'd0;
        layer_sel      = (state >= S_L2_REQ);

        // run-phase windows
        mult_en        = (state == S_L1_RUN)  ||
                         (state == S_L2_RUN0) ||
                         (state == S_L2_RUN1);
        buf_wr_en      = mult_en;
        buf_rd_en      = mult_en || (state == S_L1_TAIL) || (state == S_L2_TAIL);
        buf_swap       = mult_en || (state == S_L1_TAIL) || (state == S_L2_TAIL);
        l2_rd_addr     = (state == S_L2_RUN0) ? {1'b0, beat} : 4'd7;

        // issue engine (issue-on-arrival, one row in flight)
        case (state)
            S_L1_REQ: begin
                sram_w_read_en  = 1'b1;
                sram_w_addr     = j * 112;                      // row 0 of neuron j
                sram_in_read_en = 1'b1;
                sram_in_addr    = 7'd0;
                accum_clr       = 1'b1;
            end
            S_L1_WAIT, S_L1_RUN: begin
                if (arr_l1 && (batch != 7'd111)) begin
                    sram_w_read_en  = 1'b1;
                    sram_w_addr     = j * 112 + batch + 7'd1;   // next weight row
                    sram_in_read_en = 1'b1;
                    sram_in_addr    = batch + 7'd1;             // same x row again
                end
            end
            S_L2_REQ: begin
                sram_w_read_en  = 1'b1;
                sram_w_addr     = 896 + 2 * d;                  // side 0
                accum_clr       = 1'b1;
            end
            S_L2_WAIT, S_L2_RUN0: begin
                if (arr_l2 && (side == 1'b0)) begin
                    sram_w_read_en = 1'b1;
                    sram_w_addr    = 896 + 2 * d + 11'd1;       // side 1
                end
            end
            default: ;
        endcase

        // bias / store / transfer phases
        case (state)
            S_L1_BIAS: begin
                add_start    = 1'b1;
                add_bias_sel = 1'b1;
                bias_addr    = {2'b00, j};
            end
            S_L1_STORE: begin
                l2_wr_en   = 1'b1;
                l2_wr_addr = {1'b0, j};
            end
            S_L2_BIAS: begin
                add_start    = 1'b1;
                add_bias_sel = 1'b1;
                bias_addr    = 5'd8 + {1'b0, d};
            end
            S_L2_STAGE: begin
                l2_wr_en   = 1'b1;
                l2_wr_addr = d;          // rf[8+d] <= biased raw logit
            end
            default: ;
        endcase
    end

    // ---------------- state machine ----------------
    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            j           <= 3'd0;
            d           <= 4'd0;
            side        <= 1'b0;
            batch       <= 7'd0;
            beat        <= 3'd0;
            last_arr    <= 1'b0;
            add_cnt     <= 10'd0;
        end else begin
            // every completed add (product term or bias) pulses add_done;
            // TAIL uses the count to know exactly when the neuron's terms
            // are all accumulated (accounting never overflows: L1 = 785 max)
            if (add_done) add_cnt <= add_cnt + 10'd1;
            case (state)
                S_IDLE: if (start) begin
                    state    <= S_L1_REQ;
                    j        <= 3'd0;
                    batch    <= 7'd0;
                    beat     <= 3'd0;
                    last_arr <= 1'b0;
                    side     <= 1'b0;
                    add_cnt  <= 10'd0;
                end

                S_L1_REQ: begin
                    state    <= S_L1_WAIT;
                    add_cnt  <= 10'd0;   // neuron accounting restarts
                end

                S_L1_WAIT: if (arr_l1) begin
                    batch    <= batch + 7'd1;
                    state    <= S_L1_RUN;
                    beat     <= 3'd0;
                    last_arr <= (batch == 7'd111);
                end

                S_L1_RUN: begin
                    if (arr_l1) begin
                        batch    <= batch + 7'd1;
                        last_arr <= (batch == 7'd111);
                    end
                    if (last_arr && (beat == 3'd6)) begin
                        state <= S_L1_TAIL;      // after row 111's beat 6
                        beat  <= 3'd0;
                    end else begin
                        beat <= (beat == 3'd6) ? 3'd0 : (beat + 3'd1);
                    end
                end

                S_L1_TAIL: if (add_cnt == 10'd784) state <= S_L1_BIAS;
                // BIAS is one cycle: the adder registers accum+bias at the
                // edge that closes this state (add_done only REPORTS it).
                S_L1_BIAS: state <= S_L1_STORE;

                S_L1_STORE: begin
                    batch    <= 7'd0;
                    beat     <= 3'd0;
                    last_arr <= 1'b0;
                    if (j == 3'd7) begin
                        state <= S_L2_REQ;
                        d     <= 4'd0;
                        side  <= 1'b0;
                    end else begin
                        state <= S_L1_REQ;
                        j     <= j + 3'd1;
                    end
                end

                S_L2_REQ: begin
                    state    <= S_L2_WAIT;
                    side     <= 1'b0;
                    beat     <= 3'd0;
                    last_arr <= 1'b0;
                    add_cnt  <= 10'd0;
                end

                S_L2_WAIT: if (arr_l2) begin
                    state    <= S_L2_RUN0;
                    beat     <= 3'd0;
                    side     <= 1'b1;        // side 1 now in flight
                    last_arr <= 1'b0;
                end

                S_L2_RUN0: begin
                    if (arr_l2) begin       // side 1 arrives at beat 6
                        state    <= S_L2_RUN1;
                        beat     <= 3'd0;
                        last_arr <= 1'b1;
                    end else begin
                        beat <= (beat == 3'd6) ? 3'd0 : (beat + 3'd1);
                    end
                end

                S_L2_RUN1: begin
                    if (last_arr && (beat == 3'd6)) begin
                        state <= S_L2_TAIL;
                        beat  <= 3'd0;
                    end else begin
                        beat <= (beat == 3'd6) ? 3'd0 : (beat + 3'd1);
                    end
                end

                S_L2_TAIL: if (add_cnt == 10'd14) state <= S_L2_BIAS;
                // BIAS is one cycle (same reasoning as S_L1_BIAS).
                S_L2_BIAS: state <= S_L2_STAGE;

                S_L2_STAGE: begin
                    if (d == 4'd9) begin
                        state <= S_DONE;    // digit 9 already in rf[17]
                    end else begin
                        state <= S_L2_REQ;
                        d     <= d + 4'd1;
                    end
                end

                S_DONE: state <= S_IDLE;

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------- status ----------------
    always @* begin
        busy = (state != S_IDLE);
        done = (state == S_DONE);
    end

    // mult_valid and buf_full are accepted per the interface contract but not
    // needed by this zero-stall schedule (the write window is derived from the
    // RUN state and the buffer never overflows by construction).
    wire unused_ok = mult_valid & buf_full;

endmodule

// ============================ fcnn_top.v ============================
// ============================================================================
// Module      : fcnn_top  (Step 8.1 - 8.3 of 05_plan.md)
// Project     : HW1 - FP16 FCNN Accelerator for MNIST (IEEE 754 half)
// Description : Top-level integration: fcnn_controller + fcnn_datapath.
//               The accelerator computes one fixed 784-8-10 FCNN inference
//               with FP16 (IEEE 754 half) arithmetic under the resource
//               constraints: exactly 1 multiplier + 1 adder (Q3), ReLU only
//               on layer 1 (Q4), bias added LAST (Q6).
//               Outputs: 10 parallel logits (16 bit each), the predicted
//               digit and the done busy handshake.
// ============================================================================
`timescale 1ns/1ps

module fcnn_top (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    output wire         busy,
    output wire         done,
    output wire [159:0] logits_out,    // 10 L2 outputs, logits[d] at [159-16d -: 16] (d=0 on the MSBs)
    output wire [3:0]   pred_digit     // ArgMax over logits_out
);

    // ---------------- controller -> datapath control ----------------
    wire [9:0]  sram_w_addr;
    wire        sram_w_read_en;
    wire [6:0]  sram_in_addr;
    wire        sram_in_read_en;
    wire        mult_en;
    wire [2:0]  mult_elem_sel;
    wire        buf_wr_en;
    wire        buf_rd_en;
    wire        buf_swap;
    wire        add_start;
    wire        add_bias_sel;
    wire        accum_clr;
    wire        layer_sel;
    wire [4:0]  bias_addr;
    wire        l2_wr_en;
    wire [3:0]  l2_wr_addr;
    wire [3:0]  l2_rd_addr;

    // ---------------- datapath -> controller status ----------------
    wire        sram_w_valid;
    wire        sram_in_valid;
    wire        mult_valid;
    wire        buf_full;
    wire        buf_empty;
    wire        add_done;

    fcnn_controller u_ctrl (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .sram_w_valid (sram_w_valid),
        .sram_in_valid(sram_in_valid),
        .mult_valid   (mult_valid),
        .buf_full     (buf_full),
        .buf_empty    (buf_empty),
        .add_done     (add_done),
        .sram_w_addr  (sram_w_addr),
        .sram_w_read_en(sram_w_read_en),
        .sram_in_addr (sram_in_addr),
        .sram_in_read_en(sram_in_read_en),
        .mult_en      (mult_en),
        .mult_elem_sel(mult_elem_sel),
        .buf_wr_en    (buf_wr_en),
        .buf_rd_en    (buf_rd_en),
        .buf_swap     (buf_swap),
        .add_start    (add_start),
        .add_bias_sel (add_bias_sel),
        .accum_clr    (accum_clr),
        .layer_sel    (layer_sel),
        .bias_addr    (bias_addr),
        .l2_wr_en     (l2_wr_en),
        .l2_wr_addr   (l2_wr_addr),
        .l2_rd_addr   (l2_rd_addr),
        .busy         (busy),
        .done         (done)
    );

    fcnn_datapath u_dp (
        .clk            (clk),
        .rst            (rst),
        .sram_w_addr    (sram_w_addr),
        .sram_w_read_en (sram_w_read_en),
        .sram_in_addr   (sram_in_addr),
        .sram_in_read_en(sram_in_read_en),
        .sram_w_valid   (sram_w_valid),
        .sram_in_valid  (sram_in_valid),
        .mult_en        (mult_en),
        .mult_elem_sel  (mult_elem_sel),
        .mult_valid     (mult_valid),
        .buf_wr_en      (buf_wr_en),
        .buf_rd_en      (buf_rd_en),
        .buf_swap       (buf_swap),
        .buf_full       (buf_full),
        .buf_empty      (buf_empty),
        .add_start      (add_start),
        .add_bias_sel   (add_bias_sel),
        .accum_clr      (accum_clr),
        .add_done       (add_done),
        .layer_sel      (layer_sel),
        .bias_addr      (bias_addr),
        .l2_wr_en       (l2_wr_en),
        .l2_wr_addr     (l2_wr_addr),
        .l2_rd_addr     (l2_rd_addr),
        .logits_out     (logits_out),
        .pred_digit     (pred_digit)
    );

endmodule
