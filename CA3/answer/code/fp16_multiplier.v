// ============================================================================
// fp16_multiplier_modular.v
// Same design / same ports / same 286 cells as fp16_multiplier.v, but split
// into small sub-modules (in the style of fa3).  Only c1, c2, s1, s2 from
// modules.v are used as leaf cells.
//
// Hierarchy
//   fp16_multiplier
//    |- mul3      : 3M = M + 2M                              (28 cells)
//    |- pp_row    : one radix-4 partial-product row  x5      (54 cells)
//    |- acc_init  : row 0 = starting value of the accumulator (1 cell)
//    |- acc_row   : acc[k] = acc[k-1] + row_k  (k=1..4)     (4 x 32 cells)
//    |- hid_row   : + hidden-bit row, gives p[21:10]         (31 cells)
//    |- exp_add   : E = e_a + e_b + p21                      (15 cells)
//    |- exp_dec   : r = E - 15                               (5 cells)
//    |- exp_nz    : exponent != 0 (OR5) x2                   (4 cells)
//    |- flags     : kill_e / kill_m / X                      (3 cells)
//    |- frac_ff / exp_ff0 / exp_ff / sign_ff / valid_ff      (17 cells)
// ============================================================================
`timescale 1ns/1ps

// ----------------------------------------------------------------------------
// fa3 : full adder made of 3 c2 cells
// ----------------------------------------------------------------------------
module fa3 (input wire x, y, z, output wire s, co);
    wire t;
    c2 u_t  (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
             .A1(y), .B1(1'b0), .A0(x), .B0(1'b1), .out(t));
    c2 u_s  (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
             .A1(t), .B1(1'b0), .A0(z), .B0(1'b1), .out(s));
    c2 u_co (.D00(1'b0), .D01(z), .D10(z), .D11(1'b1),
             .A1(y), .B1(1'b0), .A0(x), .B0(1'b1), .out(co));
endmodule

// ----------------------------------------------------------------------------
// mul3 : t = bits 10..0 of 3M, M = {1, a[9:0]}.
//        3M[12] = t_c11, 3M[11] = ~t_c11                         28 cells
// ----------------------------------------------------------------------------
module mul3 (input wire [9:0] a, output wire [10:0] t, output wire t_c11);
    wire [10:2] t_c;
    genvar i;

    assign t[0] = a[0];
    // bit 1 : half adder a1 + a0
    c2 u_t1  (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
              .A1(a[1]), .B1(1'b0), .A0(a[0]), .B0(1'b1), .out(t[1]));
    c2 u_tc2 (.D00(1'b0), .D01(1'b1), .D10(1'b0), .D11(1'b0),
              .A1(1'b0), .B1(1'b0), .A0(a[1]), .B0(a[0]), .out(t_c[2]));
    // bits 2..9 : full adders
    generate
        for (i = 2; i <= 9; i = i + 1) begin : g_3m
            fa3 u_fa (.x(a[i]), .y(a[i-1]), .z(t_c[i]), .s(t[i]), .co(t_c[i+1]));
        end
    endgenerate
    // bit 10 : 1 + a9 + c
    c2 u_t10 (.D00(1'b1), .D01(1'b0), .D10(1'b0), .D11(1'b1),
              .A1(t_c[10]), .B1(1'b0), .A0(a[9]), .B0(1'b1), .out(t[10]));
    c2 u_t11 (.D00(1'b0), .D01(1'b0), .D10(1'b1), .D11(1'b1),
              .A1(a[9]), .B1(t_c[10]), .A0(1'b0), .B0(1'b0), .out(t_c11));
endmodule

// ----------------------------------------------------------------------------
// pp_row : one radix-4 row, digit d = {b1,b0}
//          pp[i] = bit i of d*M (i = 1..10),  hi = b1 & b0 & t_c11
//          SKIP1 = 1 : bit 1 is not built (row 0)             10 or 11 cells
// ----------------------------------------------------------------------------
module pp_row #(parameter SKIP1 = 0) (
    input  wire [10:0] m,
    input  wire [10:0] t,
    input  wire        b1, b0, t_c11,
    output wire [10:1] pp,
    output wire        hi);
    genvar i;
    generate
        for (i = 1; i <= 10; i = i + 1) begin : g_pp
            if (!(SKIP1 && i == 1)) begin : g_mux
                c2 u_pp (.D00(1'b0), .D01(m[i]), .D10(m[i-1]), .D11(t[i]),
                         .A1(b1), .B1(1'b0), .A0(b0), .B0(1'b1), .out(pp[i]));
            end
        end
    endgenerate
    c2 u_hi (.D00(1'b0), .D01(t_c11), .D10(1'b0), .D11(1'b0),
             .A1(1'b0), .B1(1'b0), .A0(b1), .B0(b0), .out(hi));
endmodule

// ----------------------------------------------------------------------------
// acc_init : starting value of the accumulator (row 0)            1 cell
//            acc[11] = b1 & ~(b0 & c11),  acc[12] = hi0
// ----------------------------------------------------------------------------
module acc_init (
    input  wire        b1, b0, t_c11, hi,
    input  wire [10:2] pp,
    output wire [12:2] acc);
    assign acc[10:2] = pp;
    c2 u_acc0_11 (.D00(1'b0), .D01(1'b0), .D10(1'b1), .D11(1'b0),
                  .A1(b1), .B1(1'b0), .A0(b0), .B0(t_c11), .out(acc[11]));
    assign acc[12] = hi;
endmodule

// ----------------------------------------------------------------------------
// acc_row : acc_out = acc_in + row_K << 2K   (K = 1..4)           32 cells
//           b0 = b[2K], b1 = b[2K+1], a0 = a[0]
// ----------------------------------------------------------------------------
module acc_row #(parameter K = 1) (
    input  wire                 a0, b0, b1, hi,
    input  wire [2*K+10:2*K]    acc_in,
    input  wire [10:1]          pp,
    output wire [2*K+12:2*K+2]  acc_out);

    wire [2*K+11:2*K+1] cy;
    genvar j;

    // column 2K : only the carry is needed (low bit is dropped)
    c2 u_c0 (.D00(1'b0), .D01(acc_in[2*K]), .D10(1'b0), .D11(1'b0),
             .A1(1'b0), .B1(1'b0), .A0(a0), .B0(b0), .out(cy[2*K+1]));
    // column 2K+1 : carry only (majority)
    c2 u_c1 (.D00(1'b0), .D01(cy[2*K+1]), .D10(cy[2*K+1]), .D11(1'b1),
             .A1(pp[1]), .B1(1'b0), .A0(acc_in[2*K+1]), .B0(1'b1),
             .out(cy[2*K+2]));
    // columns 2K+2 .. 2K+10 : full adders
    generate
        for (j = 2*K+2; j <= 2*K+10; j = j + 1) begin : g_col
            fa3 u_fa (.x(acc_in[j]), .y(pp[j-2*K]), .z(cy[j]),
                      .s(acc_out[j]), .co(cy[j+1]));
        end
    endgenerate
    // column 2K+11 : top of the row
    fa3 u_top (.x(b1), .y(hi), .z(cy[2*K+11]),
               .s(acc_out[2*K+11]), .co(acc_out[2*K+12]));
endmodule

// ----------------------------------------------------------------------------
// hid_row : p = acc4 + (M << 10)  -> product bits 21..10           31 cells
// ----------------------------------------------------------------------------
module hid_row (
    input  wire [9:0]   a,
    input  wire [20:10] acc_in,
    output wire [21:10] p);
    wire [20:11] cy;
    genvar j;

    c2 u_p10 (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
              .A1(acc_in[10]), .B1(1'b0), .A0(a[0]), .B0(1'b1), .out(p[10]));
    c2 u_c11 (.D00(1'b0), .D01(1'b1), .D10(1'b0), .D11(1'b0),
              .A1(1'b0), .B1(1'b0), .A0(acc_in[10]), .B0(a[0]), .out(cy[11]));
    generate
        for (j = 11; j <= 19; j = j + 1) begin : g_hid
            fa3 u_fa (.x(acc_in[j]), .y(a[j-10]), .z(cy[j]), .s(p[j]), .co(cy[j+1]));
        end
    endgenerate
    // column 20 : acc + 1 + carry
    c2 u_p20 (.D00(1'b1), .D01(1'b0), .D10(1'b0), .D11(1'b1),
              .A1(cy[20]), .B1(1'b0), .A0(acc_in[20]), .B0(1'b1), .out(p[20]));
    c2 u_p21 (.D00(1'b0), .D01(1'b0), .D10(1'b1), .D11(1'b1),
              .A1(acc_in[20]), .B1(cy[20]), .A0(1'b0), .B0(1'b0), .out(p[21]));
endmodule

// ----------------------------------------------------------------------------
// exp_add : E = ea + eb + cin  (6 bit)                             15 cells
// ----------------------------------------------------------------------------
module exp_add (
    input  wire [4:0] ea, eb,
    input  wire       cin,
    output wire [5:0] E);
    wire [5:0] ec;
    genvar i;
    assign ec[0] = cin;
    generate
        for (i = 0; i < 5; i = i + 1) begin : g_exp
            fa3 u_fa (.x(ea[i]), .y(eb[i]), .z(ec[i]), .s(E[i]), .co(ec[i+1]));
        end
    endgenerate
    assign E[5] = ec[5];
endmodule

// ----------------------------------------------------------------------------
// exp_dec : r = E - 15 = E + 17   (r[0] = ~E0 is folded into its flop)
//                                                                  5 cells
// ----------------------------------------------------------------------------
module exp_dec (
    input  wire [5:0] E,
    output wire       g3,        // E0 & E1 & E2
    output wire [4:1] r);

    c2 u_g3 (.D00(1'b0), .D01(E[2]), .D10(1'b0), .D11(1'b0),
             .A1(1'b0), .B1(1'b0), .A0(E[0]), .B0(E[1]), .out(g3));
    c2 u_r1 (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
             .A1(E[1]), .B1(1'b0), .A0(E[0]), .B0(1'b1), .out(r[1]));
    c2 u_r2 (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
             .A1(E[2]), .B1(1'b0), .A0(E[1]), .B0(E[0]), .out(r[2]));
    c2 u_r3 (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
             .A1(E[3]), .B1(1'b0), .A0(g3),   .B0(1'b1), .out(r[3]));
    c2 u_r4 (.D00(1'b1), .D01(1'b0), .D10(1'b0), .D11(1'b1),
             .A1(E[4]), .B1(1'b0), .A0(E[3]), .B0(g3),   .out(r[4]));
endmodule

// ----------------------------------------------------------------------------
// exp_nz : nz = |e[4:0]   (OR5)                                    2 cells
// ----------------------------------------------------------------------------
module exp_nz (input wire [4:0] e, output wire nz);
    wire w;
    c1 u_w  (.S0(e[0]), .S1(e[1]), .SB(1'b0), .B1(1'b1), .B0(1'b1),    // OR4
             .SA(e[2]), .A1(1'b1), .A0(e[3]), .f(w));
    c2 u_nz (.D00(1'b0), .D01(1'b0), .D10(1'b1), .D11(1'b1),
             .A1(w), .B1(e[4]), .A0(1'b0), .B0(1'b0), .out(nz));
endmodule

// ----------------------------------------------------------------------------
// flags : zero / underflow / overflow                              3 cells
//   kill_e = zero | unf,  X = E4 | E3&E2&E1,  kill_m = kill_e | E5&X
// ----------------------------------------------------------------------------
module flags (
    input  wire [5:0] E,
    input  wire       nz_a, nz_b,
    output wire       kill_e, X, kill_m);

    c2 u_kill_e (.D00(1'b1), .D01(1'b1), .D10(1'b1), .D11(1'b0),
                 .A1(E[5]), .B1(E[4]), .A0(nz_a), .B0(nz_b), .out(kill_e));
    c2 u_X    (.D00(1'b0), .D01(E[1]), .D10(1'b1), .D11(1'b1),
               .A1(E[4]), .B1(1'b0), .A0(E[3]), .B0(E[2]), .out(X));
    c1 u_kill_m (.S0(kill_e), .S1(1'b0), .SB(1'b0), .B1(1'b1), .B0(1'b1),
                 .SA(E[5]), .A1(X), .A0(1'b0), .f(kill_m));
endmodule

// ----------------------------------------------------------------------------
// output registers (one s2 each)
// ----------------------------------------------------------------------------
// mantissa bit : kill_m ? 0 : (p21 ? p_hi : p_lo)
module frac_ff (input wire p_lo, p_hi, kill_m, p21, clr, clk, output wire q);
    s2 u_q (.D00(p_lo), .D01(p_hi), .D10(1'b0), .D11(1'b0),
            .A1(kill_m), .B1(1'b0), .A0(p21), .B0(1'b1),
            .clr(clr), .clk(clk), .out(q));
endmodule

// exponent bit 0 : kill ? 0 : ovf ? 1 : ~E0
module exp_ff0 (input wire kill_e, E0, E5, X, clr, clk, output wire q);
    s2 u_q (.D00(1'b1), .D01(1'b1), .D10(1'b0), .D11(1'b1),
            .A1(kill_e), .B1(E0), .A0(E5), .B0(X),
            .clr(clr), .clk(clk), .out(q));
endmodule

// exponent bits 1..4 : kill_e ? 0 : ovf ? 1 : r
module exp_ff (input wire r, kill_e, E5, X, clr, clk, output wire q);
    s2 u_q (.D00(r), .D01(1'b1), .D10(1'b0), .D11(1'b0),
            .A1(kill_e), .B1(1'b0), .A0(E5), .B0(X),
            .clr(clr), .clk(clk), .out(q));
endmodule

// sign : a15 ^ b15
module sign_ff (input wire sa, sb, clr, clk, output wire q);
    s2 u_q (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
            .A1(sa), .B1(1'b0), .A0(sb), .B0(1'b1),
            .clr(clr), .clk(clk), .out(q));
endmodule

// valid pipeline flop
module valid_ff (input wire d, clr, clk, output wire q);
    s1 u_qv (.D00(d), .D01(1'b0), .D10(1'b0), .D11(1'b0),
             .A1(1'b0), .B1(1'b0), .A0(1'b0),
             .clr(clr), .clk(clk), .out(q));
endmodule

// ============================================================================
// Top level
// ============================================================================
module fp16_multiplier (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output wire [15:0] result,
    output wire        valid_out
);
    genvar k, i;

    // ---- 1) 3M -----------------------------------------------------------
    wire [10:0] m = {1'b1, a[9:0]};
    wire [10:0] t;
    wire        t_c11;

    mul3 u_mul3 (.a(a[9:0]), .t(t), .t_c11(t_c11));

    // ---- 2) radix-4 partial-product rows ---------------------------------
    wire [10:1] pp [0:4];
    wire [4:0]  hi;

    generate
        for (k = 0; k < 5; k = k + 1) begin : g_row
            pp_row #(.SKIP1(k == 0)) u_row (
                .m(m), .t(t),
                .b1(b[2*k+1]), .b0(b[2*k]), .t_c11(t_c11),
                .pp(pp[k]), .hi(hi[k]));
        end
    endgenerate

    // ---- 3) accumulation -------------------------------------------------
    wire [21:0] acc [0:4];
    wire [21:10] p;

    acc_init u_acc0 (.b1(b[1]), .b0(b[0]), .t_c11(t_c11), .hi(hi[0]),
                     .pp(pp[0][10:2]), .acc(acc[0][12:2]));

    generate
        for (k = 1; k < 5; k = k + 1) begin : g_add
            acc_row #(.K(k)) u_row (
                .a0(a[0]), .b0(b[2*k]), .b1(b[2*k+1]), .hi(hi[k]),
                .acc_in(acc[k-1][2*k+10:2*k]),
                .pp(pp[k]),
                .acc_out(acc[k][2*k+12:2*k+2]));
        end
    endgenerate

    hid_row u_hid (.a(a[9:0]), .acc_in(acc[4][20:10]), .p(p));

    // ---- 4) exponent -----------------------------------------------------
    wire [5:0] E;
    wire       g3;
    wire [4:1] r;

    exp_add u_eadd (.ea(a[14:10]), .eb(b[14:10]), .cin(p[21]), .E(E));
    exp_dec u_edec (.E(E), .g3(g3), .r(r));

    // ---- 5) zero / underflow / overflow ----------------------------------
    wire nz_a, nz_b, kill_e, X, kill_m;

    exp_nz u_nz_a (.e(a[14:10]), .nz(nz_a));
    exp_nz u_nz_b (.e(b[14:10]), .nz(nz_b));
    flags  u_flags (.E(E), .nz_a(nz_a), .nz_b(nz_b),
                    .kill_e(kill_e), .X(X), .kill_m(kill_m));

    // ---- 6) output registers ---------------------------------------------
    generate
        for (i = 0; i < 10; i = i + 1) begin : g_frac
            frac_ff u_q (.p_lo(p[i+10]), .p_hi(p[i+11]), .kill_m(kill_m),
                         .p21(p[21]), .clr(rst), .clk(clk), .q(result[i]));
        end
    endgenerate

    exp_ff0 u_q10 (.kill_e(kill_e), .E0(E[0]), .E5(E[5]), .X(X),
                   .clr(rst), .clk(clk), .q(result[10]));

    generate
        for (i = 1; i < 5; i = i + 1) begin : g_exp_q
            exp_ff u_q (.r(r[i]), .kill_e(kill_e), .E5(E[5]), .X(X),
                        .clr(rst), .clk(clk), .q(result[10+i]));
        end
    endgenerate

    sign_ff  u_q15 (.sa(a[15]), .sb(b[15]), .clr(rst), .clk(clk), .q(result[15]));
    valid_ff u_qv  (.d(valid_in), .clr(rst), .clk(clk), .q(valid_out));

endmodule
