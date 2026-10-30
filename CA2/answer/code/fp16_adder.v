// ============================================================================
// fp16_adder.v  -  FP16 accumulator-adder, hand-synthesized on Actel cells
//
// Interface identical to the Project-1 adder:
//     accum <= accum + operand_b      when start_add = 1   (clr_accum has priority)
//
// Functional spec (Project-2 / phase-1):
//   * an operand whose exponent field is 0 (zero / subnormal) is treated as 0
//   * the exact sum is TRUNCATED (round toward zero), no rounding logic
//   * result exponent <= 0  -> result = +0          (underflow)
//   * result exponent >= 31 -> {sign, 5'h1F, 10'h0} (overflow)
//   * exact cancellation    -> +0
//
// Only the cells c1 / s2 are used (through actel_gates.v):  NO logic operators.
//
// Architecture (one clock cycle, everything in front of the accumulator FFs):
//   nz_detect5 x2 -> mag_cmp15 -> operand_swap -> exp_diff -> align_shifter
//   -> addsub12 -> normalizer -> exp_calc -> accumulator (s2 flip-flops)
//
// The accumulator flip-flop is an s2 cell whose built-in 4:1 mux performs
//   hold / load / clear / force-1  - so clear, enable and the "force result to
//   zero / inf" decisions cost no extra gates.
// ============================================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// nz = (e != 0)                                                   2 x c1
// ---------------------------------------------------------------------------
module nz_detect5 (input [4:0] e, output nz);
    wire lo;
    g_or  u_lo (.a(e[1]), .b(e[0]), .y(lo));
    g_or4 u_nz (.a(e[4]), .b(e[3]), .c(e[2]), .d(lo), .y(nz));
endmodule

// ---------------------------------------------------------------------------
// ge = (a >= b)   unsigned 15-bit magnitude compare (ripple, LSB first)  15 x c1
// ---------------------------------------------------------------------------
module mag_cmp15 (input [14:0] a, b, output ge);
    wire [15:0] c;
    assign c[0] = 1'b1;                 // equal -> "greater or equal"
    genvar i;
    generate
        for (i = 0; i < 15; i = i + 1) begin : slice
            g_cmp u (.a(a[i]), .b(b[i]), .gp(c[i]), .y(c[i+1]));
        end
    endgenerate
    assign ge = c[15];
endmodule

// ---------------------------------------------------------------------------
// Choose the bigger / smaller operand (g = 1 : A is the bigger one).
// Zero (exp field == 0) operands are masked here, for free, by g_mmux2.
//                                                                  28 x c1
// ---------------------------------------------------------------------------
module operand_swap (
    input         g,
    input  [4:0]  ea, eb,
    input  [9:0]  fa, fb,
    input         nza, nzb, sa, sb,
    output [4:0]  ebig,
    output [9:0]  big_f, small_f,
    output        big_h, small_h,
    output        sbig
);
    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : g_exp
            g_mux2 u (.a0(eb[i]), .a1(ea[i]), .s(g), .y(ebig[i]));
        end
        for (i = 0; i < 10; i = i + 1) begin : g_frac
            // big   : g ? (nza ? fa : 0) : (nzb ? fb : 0)
            g_mmux2 ub (.d0(fb[i]), .m0(nzb), .d1(fa[i]), .m1(nza), .s(g), .y(big_f[i]));
            // small : g ? (nzb ? fb : 0) : (nza ? fa : 0)
            g_mmux2 us (.d0(fa[i]), .m0(nza), .d1(fb[i]), .m1(nzb), .s(g), .y(small_f[i]));
        end
    endgenerate
    g_mux2 u_bh (.a0(nzb), .a1(nza), .s(g), .y(big_h));     // hidden bits
    g_mux2 u_sh (.a0(nza), .a1(nzb), .s(g), .y(small_h));
    g_mux2 u_sg (.a0(sb),  .a1(sa),  .s(g), .y(sbig));
endmodule

// ---------------------------------------------------------------------------
// d = |ea - eb| = ebig - esmall  (5 bit)                           14 x c1
//   p_i = ~(ea_i ^ eb_i)      (= ebig_i ^ ~esmall_i, independent of the swap)
//   ebig + ~esmall + 1 :   d_i = p_i ^ c_i ,   c_{i+1} = p_i ? c_i : ebig_i
// ---------------------------------------------------------------------------
module exp_diff (input [4:0] ea, eb, ebig, output [4:0] d);
    wire [4:0] p;
    wire [5:0] c;
    assign c[0] = 1'b1;
    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : slc
            g_xnor ux (.a(ea[i]), .b(eb[i]), .y(p[i]));
            g_xor  us (.a(p[i]),  .b(c[i]),  .y(d[i]));
            if (i < 4) begin : cy
                g_mux2 uc (.a0(ebig[i]), .a1(c[i]), .s(p[i]), .y(c[i+1]));
            end
        end
    endgenerate
endmodule

// ---------------------------------------------------------------------------
// Right alignment of the small significand by d, with sticky bit.  33 x c1
//   w  = {hidden, frac, 1'b0}  (12 bit, bit0 = guard position)
//   y  = w >> d                (guard bit = y[0])
//   sticky = OR of all bits shifted out below the guard bit  (w[d-1:0])
//   d >= 12 saturates : y = 0 , sticky = w[11] (small operand non-zero)
// ---------------------------------------------------------------------------
module align_shifter (input [11:0] w, input [4:0] d, output [11:0] y, output sticky);
    // ---- saturation of the coarse stage select ----
    wire sb1, sb0;
    g_or u_sb1 (.a(d[3]), .b(d[4]), .y(sb1));
    g_or u_sb0 (.a(d[2]), .b(d[4]), .y(sb0));

    // ---- stage A : shift by d[1:0]  (0..3) ----
    wire [15:0] wp;
    assign wp = {4'b0000, w};
    wire [11:0] x;
    // ---- stage B : shift by 4*{sb1,sb0}  (0,4,8,12) ----
    wire [23:0] xp;
    assign xp = {12'b000000000000, x};
    genvar i;
    generate
        for (i = 0; i < 12; i = i + 1) begin : st
            g_mux4 ua (.d0(wp[i]), .d1(wp[i+1]), .d2(wp[i+2]), .d3(wp[i+3]),
                       .s1(d[1]), .s0(d[0]), .y(x[i]));
            g_mux4 ub (.d0(xp[i]), .d1(xp[i+4]), .d2(xp[i+8]), .d3(xp[i+12]),
                       .s1(sb1), .s0(sb0), .y(y[i]));
        end
    endgenerate

    // ---- sticky ----
    wire w12, la, t4, t8, u8, lb;
    g_or   u_w12 (.a(w[1]), .b(w[2]), .y(w12));
    g_mux4 u_la  (.d0(1'b0), .d1(1'b0), .d2(w[1]), .d3(w12), .s1(d[1]), .s0(d[0]), .y(la));
    g_or4  u_t4  (.a(x[0]), .b(x[1]), .c(x[2]),  .d(x[3]),  .y(t4));
    g_or4  u_t8  (.a(x[4]), .b(x[5]), .c(x[6]),  .d(x[7]),  .y(t8));
    g_or   u_u8  (.a(t4),   .b(t8),   .y(u8));
    g_mux4 u_lb  (.d0(1'b0), .d1(t4), .d2(u8), .d3(w[11]), .s1(sb1), .s0(sb0), .y(lb));
    g_or   u_stk (.a(la), .b(lb), .y(sticky));
endmodule

// ---------------------------------------------------------------------------
// r = a + y            (sub = 0)
// r = a - y - sticky   (sub = 1, cin = ~sticky : a + ~y + cin)         38 x c1
// full adder per bit = 3 cells : p = a^y^sub , s = p^c , cout = p ? c : a
// ---------------------------------------------------------------------------
module addsub12 (input [11:0] a, y, input sub, nsub, cin, output [12:0] r);
    wire [12:0] c;
    wire [11:0] p;
    assign c[0] = cin;
    genvar i;
    generate
        for (i = 0; i < 12; i = i + 1) begin : fa
            g_xor3 up (.a(a[i]), .b(y[i]), .s(sub), .ns(nsub), .y(p[i]));
            g_xor  us (.a(p[i]), .b(c[i]), .y(r[i]));
            g_mux2 uc (.a0(a[i]), .a1(c[i]), .s(p[i]), .y(c[i+1]));
        end
    endgenerate
    g_and u_top (.a(c[12]), .b(nsub), .y(r[12]));   // carry out only for additions
endmodule

// ---------------------------------------------------------------------------
// Normalizer (13-bit r, leading one -> bit 15 of {r,000}).               30 + 5 x c1
//   coarse stage : left shift by 4*hs      (hs = # leading zero nibbles)
//   fine   stage : left shift by lo        (lo = # leading zeros left)
//   frac = 10 bits after the leading one (truncated)
//   q    = (1 - lz) mod 32,  lz = 4*hs + lo   -> exponent = ebig + q
//   rz   = (r == 0)
// ---------------------------------------------------------------------------
module normalizer (input [12:0] r, output [9:0] frac, output [4:0] q, output rz);
    wire [15:0] rp;
    assign rp = {r, 3'b000};
    wire nz3, nz2, nz1, hs1, hs0;
    g_or4 u_n3 (.a(rp[15]), .b(rp[14]), .c(rp[13]), .d(rp[12]), .y(nz3));
    g_or4 u_n2 (.a(rp[11]), .b(rp[10]), .c(rp[9]),  .d(rp[8]),  .y(nz2));
    g_or4 u_n1 (.a(rp[7]),  .b(rp[6]),  .c(rp[5]),  .d(rp[4]),  .y(nz1));
    g_nor u_h1 (.a(nz3), .b(nz2), .y(hs1));
    g_lz  u_h0 (.x2(nz3), .x1(nz2), .x0(nz1), .y(hs0));

    // ---- coarse stage ----
    wire [27:0] rpp;
    assign rpp = {rp, 12'b000000000000};
    wire [15:0] x1;
    assign x1[2:0] = 3'b000;
    genvar j;
    generate
        for (j = 3; j < 16; j = j + 1) begin : coarse
            g_mux4 u (.d0(rpp[j+12]), .d1(rpp[j+8]), .d2(rpp[j+4]), .d3(rpp[j]),
                      .s1(hs1), .s0(hs0), .y(x1[j]));
        end
    endgenerate

    // ---- fine stage ----
    wire lo1, lo0;
    g_nor u_l1 (.a(x1[15]), .b(x1[14]), .y(lo1));
    g_lz  u_l0 (.x2(x1[15]), .x1(x1[14]), .x0(x1[13]), .y(lo0));
    genvar k;
    generate
        for (k = 0; k < 10; k = k + 1) begin : fine
            g_mux4 u (.d0(x1[k+5]), .d1(x1[k+4]), .d2(x1[k+3]), .d3(x1[k+2]),
                      .s1(lo1), .s0(lo0), .y(frac[k]));
        end
    endgenerate

    // ---- exponent code  q = (1 - (4*hs + lo)) mod 32 ----
    wire c3;
    g_not  u_q0 (.a(lo0), .y(q[0]));
    assign q[1] = lo1;
    g_xor  u_q2 (.a(hs0), .b(lo1), .y(q[2]));
    g_nor  u_c3 (.a(hs0), .b(lo1), .y(c3));
    g_xnor u_q3 (.a(hs1), .b(c3),  .y(q[3]));
    g_mux2 u_q4 (.a0(1'b1), .a1(hs1), .s(c3), .y(q[4]));

    // ---- r == 0  ->  all nibbles zero and r[0] = 0 ----
    g_andn2 u_rz (.a(r[0]), .b(hs1), .c(hs0), .y(rz));
endmodule

// ---------------------------------------------------------------------------
// e = ebig + q (mod 32) plus under/overflow detection                  24 x c1
//   q[4] = 1 : exponent decreases ->  underflow if (no carry) or e == 0
//   q[4] = 0 : exponent grows     ->  overflow  if carry or e == 31
// ---------------------------------------------------------------------------
module exp_calc (input [4:0] ebig, q, output [4:0] e, output under, ovf);
    wire [5:0] c;
    wire [4:0] p;
    // bit 0 : half adder
    g_xor u_s0 (.a(ebig[0]), .b(q[0]), .y(e[0]));
    g_and u_c1 (.a(ebig[0]), .b(q[0]), .y(c[1]));
    genvar i;
    generate
        for (i = 1; i < 5; i = i + 1) begin : fa
            g_xor  up (.a(ebig[i]), .b(q[i]), .y(p[i]));
            g_xor  us (.a(p[i]),    .b(c[i]), .y(e[i]));
            g_mux2 uc (.a0(ebig[i]), .a1(c[i]), .s(p[i]), .y(c[i+1]));
        end
    endgenerate
    // e == 0  and  e == 31
    wire z1, zs, a3, os;
    g_nor      u_z1 (.a(e[1]), .b(e[0]), .y(z1));
    g_nor3_and u_zs (.a(e[4]), .b(e[3]), .c(e[2]), .d(z1), .y(zs));
    g_and3     u_a3 (.a(e[0]), .b(e[1]), .c(e[2]), .y(a3));
    g_and3     u_os (.a(a3),   .b(e[3]), .c(e[4]), .y(os));
    g_under u_un (.q4(q[4]), .c5(c[5]), .zs(zs), .y(under));
    g_ovf   u_ov (.q4(q[4]), .c5(c[5]), .os(os), .y(ovf));
endmodule

// ---------------------------------------------------------------------------
// Top level
// ---------------------------------------------------------------------------
module fp16_adder (
    input         clk,
    input         rst,           // clears the accumulator
    input         clr_accum,     // synchronous clear, priority over start_add
    input         start_add,     // 1-cycle pulse: accum <= accum + operand_b
    input  [15:0] operand_b,
    input         add_bias,      // unused (kept for interface compatibility)
    output [15:0] accum_out,
    output        add_done       // start_add delayed by one clock
);
    // ------------------------------------------------------------ unpack
    wire [15:0] A, B;
    assign A = accum_out;
    assign B = operand_b;
    wire nza, nzb;
    nz_detect5 u_nza (.e(A[14:10]), .nz(nza));
    nz_detect5 u_nzb (.e(B[14:10]), .nz(nzb));

    // ------------------------------------------------------------ which one is bigger
    wire g;
    mag_cmp15 u_cmp (.a(A[14:0]), .b(B[14:0]), .ge(g));

    wire [4:0] ebig;
    wire [9:0] big_f, small_f;
    wire       big_h, small_h, sbig;
    operand_swap u_swap (.g(g), .ea(A[14:10]), .eb(B[14:10]), .fa(A[9:0]), .fb(B[9:0]),
                         .nza(nza), .nzb(nzb), .sa(A[15]), .sb(B[15]),
                         .ebig(ebig), .big_f(big_f), .small_f(small_f),
                         .big_h(big_h), .small_h(small_h), .sbig(sbig));

    wire sub, nsub;
    g_xor u_sub  (.a(A[15]), .b(B[15]), .y(sub));
    g_not u_nsub (.a(sub), .y(nsub));

    // ------------------------------------------------------------ align
    wire [4:0] d;
    exp_diff u_diff (.ea(A[14:10]), .eb(B[14:10]), .ebig(ebig), .d(d));

    wire [11:0] y;
    wire        sticky;
    align_shifter u_shift (.w({small_h, small_f, 1'b0}), .d(d), .y(y), .sticky(sticky));

    // ------------------------------------------------------------ add / subtract
    wire cin;
    g_andn u_cin (.a(sticky), .b(sub), .y(cin));          // cin = sub & ~sticky
    wire [12:0] r;
    addsub12 u_add (.a({big_h, big_f, 1'b0}), .y(y), .sub(sub), .nsub(nsub),
                    .cin(cin), .r(r));

    // ------------------------------------------------------------ normalize
    wire [9:0] frac;
    wire [4:0] q;
    wire       rz;
    normalizer u_norm (.r(r), .frac(frac), .q(q), .rz(rz));

    wire [4:0] e;
    wire       under, ovf;
    exp_calc u_exp (.ebig(ebig), .q(q), .e(e), .under(under), .ovf(ovf));

    // ------------------------------------------------------------ result flags
    wire zero, zo, xf, mz, nclr, start_nz;
    g_or    u_zero (.a(rz), .b(under), .y(zero));          // result is +0
    g_or    u_zo   (.a(zero), .b(ovf), .y(zo));            // frac must be 0
    g_and   u_xf   (.a(start_add), .b(zo), .y(xf));
    g_and   u_mz   (.a(start_add), .b(zero), .y(mz));
    g_not   u_ncl  (.a(clr_accum), .y(nclr));
    g_andn  u_snz  (.a(zero), .b(start_add), .y(start_nz)); // start & ~zero

    // ------------------------------------------------------------ accumulator
    // s2 :  select = {A1|B1 , A0&B0}   D00 = hold, D01 = load,
    //                                   D10 = clear, D11 = clear / force-1
    // sign
    s2 u_sign (.D00(accum_out[15]), .D01(sbig), .D10(1'b0), .D11(1'b0),
               .A1(clr_accum), .B1(mz), .A0(start_add), .B0(1'b1),
               .clr(rst), .clk(clk), .out(accum_out[15]));
    // exponent : zero -> 00000 , overflow -> 11111
    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : ereg
            s2 u (.D00(accum_out[10+i]), .D01(e[i]), .D10(1'b0), .D11(1'b1),
                  .A1(clr_accum), .B1(xf), .A0(nclr), .B0(start_nz),
                  .clr(rst), .clk(clk), .out(accum_out[10+i]));
        end
        // fraction : zero / overflow -> 0000000000
        for (i = 0; i < 10; i = i + 1) begin : freg
            s2 u (.D00(accum_out[i]), .D01(frac[i]), .D10(1'b0), .D11(1'b0),
                  .A1(clr_accum), .B1(xf), .A0(start_add), .B0(1'b1),
                  .clr(rst), .clk(clk), .out(accum_out[i]));
        end
    endgenerate

    // add_done = start_add registered
    s2 u_done (.D00(start_add), .D01(start_add), .D10(start_add), .D11(start_add),
               .A1(1'b0), .B1(1'b0), .A0(1'b0), .B0(1'b0),
               .clr(rst), .clk(clk), .out(add_done));
endmodule
