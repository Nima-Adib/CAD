// ============================================================================
// Module      : fp16_multiplier  (TRUNCATE version, Phase-1 simplified spec)
// Project     : FP16 FCNN Accelerator for MNIST (IEEE 754 half)
// Description : FP16 multiplier mapped onto the cell library in modules.v
//               (c1, c2, s1, s2 only). Same ports, same 1-cycle latency and
//               bit-identical results to the behavioural RTL.
//
//               NOTE: rst is connected to the cells' asynchronous clr (the
//               only reset s1/s2 provide). Outputs are identical at every
//               clock edge; they just clear as soon as rst rises.
//
// Cell count  : 286  (c1 = 3, c2 = 266, s1 = 1, s2 = 16)
//                28  3*M precompute (shared by all radix-4 rows)
//                54  radix-4 partial-product rows
//               160  row accumulation (truncated low columns + final sum)
//                20  exponent adder + (E - 15)
//                 7  zero / underflow / overflow detection
//                17  output registers
//
// Algorithm
//   M_a = {1,a[9:0]}, M_b = {1,b[9:0]}, p = M_a * M_b (22 bit)
//   * M_b is split into radix-4 digits d_k = {b[2k+1],b[2k]}, k = 0..4, plus
//     the hidden bit b10 = 1.  Row k = d_k * M_a << 2k is ONE c2 per bit:
//         c2 4:1 mux, selects (b[2k+1], b[2k]), data (0, M, 2M, 3M)
//     3M = M + 2M is computed once.
//     The top of each row (bits 11,12 of d*M) equals  b[2k+1] + (b[2k+1]&b[2k]&c11)
//     at bit 11, which saves a cell per row.
//   * Rows are added one after another with ripple adders (acc_k = acc_k-1 +
//     row_k). Columns < 10 are dropped by the truncation, so there only the
//     carries are computed.
//   * frac = p21 ? p[20:11] : p[19:10], E = e_a + e_b + p21,
//     result exponent = E - 15, underflow: E < 16, overflow: E >= 46.
//     The final mux, the zero/overflow/underflow handling and the sign XOR
//     are folded into the s2 register cells.
// ============================================================================
`timescale 1ns/1ps

module fp16_multiplier (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output wire [15:0] result,
    output wire        valid_out
);

    genvar k, i, j;

    // ------------------------------------------------------------------
    // 1) 3M = M + 2M   (M = {1, a[9:0]})                        28 cells
    // ------------------------------------------------------------------
    wire [10:0] m = {1'b1, a[9:0]};
    wire [10:0] t;                       // bits 10..0 of 3M
    wire        t_c11;                   // carry into bit 11 (3M[12] = t_c11, 3M[11] = ~t_c11)
    wire [10:2] t_c;                     // ripple carries

    assign t[0] = a[0];
    // bit 1 : half adder a1 + a0
    c2 u_t1  (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
              .A1(a[1]), .B1(1'b0), .A0(a[0]), .B0(1'b1), .out(t[1]));     // a1 ^ a0
    c2 u_tc2 (.D00(1'b0), .D01(1'b1), .D10(1'b0), .D11(1'b0),
              .A1(1'b0), .B1(1'b0), .A0(a[1]), .B0(a[0]), .out(t_c[2]));   // a1 & a0
    // bits 2..9 : full adders a[i] + a[i-1] + c
    generate
        for (i = 2; i <= 9; i = i + 1) begin : g_3m
            fa3 u_fa (.x(a[i]), .y(a[i-1]), .z(t_c[i]), .s(t[i]), .co(t_c[i+1]));
        end
    endgenerate
    // bit 10 : 1 + a9 + c  ->  sum = ~(a9 ^ c), carry = a9 | c
    c2 u_t10 (.D00(1'b1), .D01(1'b0), .D10(1'b0), .D11(1'b1),
              .A1(t_c[10]), .B1(1'b0), .A0(a[9]), .B0(1'b1), .out(t[10]));
    c2 u_t11 (.D00(1'b0), .D01(1'b0), .D10(1'b1), .D11(1'b1),
              .A1(a[9]), .B1(t_c[10]), .A0(1'b0), .B0(1'b0), .out(t_c11));

    // ------------------------------------------------------------------
    // 2) radix-4 partial-product rows                           54 cells
    //    pp[k][i] = d_k*M bit i (i = 1..10), weight 2^(2k+i)
    //    (bit 0 = a0 & b[2k] is never built: it is fused into its consumer)
    //    hi[k]    = b[2k+1] & b[2k] & t_c11,  weight 2^(2k+11)
    // ------------------------------------------------------------------
    wire [10:1] pp [0:4];
    wire [4:0]  hi;

    generate
        for (k = 0; k < 5; k = k + 1) begin : g_row
            for (i = 1; i <= 10; i = i + 1) begin : g_pp
                // row 0 bit 1 (column 1) only feeds bits below the truncation
                // that nothing uses, so it is not built
                if (k > 0 || i > 1) begin : g_mux
                    c2 u_pp (.D00(1'b0), .D01(m[i]), .D10(m[i-1]), .D11(t[i]),
                             .A1(b[2*k+1]), .B1(1'b0), .A0(b[2*k]), .B0(1'b1),
                             .out(pp[k][i]));
                end
            end
            c2 u_hi (.D00(1'b0), .D01(t_c11), .D10(1'b0), .D11(1'b0),
                     .A1(1'b0), .B1(1'b0), .A0(b[2*k+1]), .B0(b[2*k]), .out(hi[k]));
        end
    endgenerate

    // ------------------------------------------------------------------
    // 3) accumulate rows: acc[k] = acc[k-1] + row_k << 2k        160 cells
    //    acc[k][j] is valid for j = 2k+2 .. 2k+12
    // ------------------------------------------------------------------
    wire [21:0] acc [0:4];
    wire [21:0] cy  [1:4];               // ripple carries of row k
    wire [21:0] p;                       // product bits 10..21
    wire [21:11] cy5;

    // row 0 is the starting value. Its top (b1 + hi0 at bit 11) is split
    // into acc0[11] = b1 & ~(b0 & c11) and acc0[12] = hi0             1 cell
    generate
        for (i = 2; i <= 10; i = i + 1) begin : g_acc0
            assign acc[0][i] = pp[0][i];
        end
    endgenerate
    c2 u_acc0_11 (.D00(1'b0), .D01(1'b0), .D10(1'b1), .D11(1'b0),
                  .A1(b[1]), .B1(1'b0), .A0(b[0]), .B0(t_c11), .out(acc[0][11]));
    assign acc[0][12] = hi[0];

    // rows 1..4                                               4 x 32 cells
    generate
        for (k = 1; k < 5; k = k + 1) begin : g_add
            // column 2k : acc + (a0 & b[2k]); the sum is a dropped low bit,
            //             so only the carry is built (the AND is fused)
            c2 u_c0 (.D00(1'b0), .D01(acc[k-1][2*k]), .D10(1'b0), .D11(1'b0),
                     .A1(1'b0), .B1(1'b0), .A0(a[0]), .B0(b[2*k]), .out(cy[k][2*k+1]));
            // column 2k+1 : also a dropped low bit -> carry only (majority)
            c2 u_c1 (.D00(1'b0), .D01(cy[k][2*k+1]), .D10(cy[k][2*k+1]), .D11(1'b1),
                     .A1(pp[k][1]), .B1(1'b0), .A0(acc[k-1][2*k+1]), .B0(1'b1),
                     .out(cy[k][2*k+2]));
            // columns 2k+2 .. 2k+10 : full adders
            for (j = 2*k+2; j <= 2*k+10; j = j + 1) begin : g_col
                fa3 u_fa (.x(acc[k-1][j]), .y(pp[k][j-2*k]), .z(cy[k][j]),
                          .s(acc[k][j]), .co(cy[k][j+1]));
            end
            // column 2k+11 : top of row k  (b[2k+1] + hi[k] + carry)
            fa3 u_top (.x(b[2*k+1]), .y(hi[k]), .z(cy[k][2*k+11]),
                       .s(acc[k][2*k+11]), .co(acc[k][2*k+12]));
        end
    endgenerate

    // hidden-bit row: p = acc4 + (M << 10)                         31 cells
    c2 u_p10 (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
              .A1(acc[4][10]), .B1(1'b0), .A0(a[0]), .B0(1'b1), .out(p[10]));
    c2 u_c11 (.D00(1'b0), .D01(1'b1), .D10(1'b0), .D11(1'b0),
              .A1(1'b0), .B1(1'b0), .A0(acc[4][10]), .B0(a[0]), .out(cy5[11]));
    generate
        for (j = 11; j <= 19; j = j + 1) begin : g_hid
            fa3 u_fa (.x(acc[4][j]), .y(a[j-10]), .z(cy5[j]), .s(p[j]), .co(cy5[j+1]));
        end
    endgenerate
    // column 20 : acc + 1 + carry -> sum = ~(acc ^ c), carry (= p21) = acc | c
    c2 u_p20 (.D00(1'b1), .D01(1'b0), .D10(1'b0), .D11(1'b1),
              .A1(cy5[20]), .B1(1'b0), .A0(acc[4][20]), .B0(1'b1), .out(p[20]));
    c2 u_p21 (.D00(1'b0), .D01(1'b0), .D10(1'b1), .D11(1'b1),
              .A1(acc[4][20]), .B1(cy5[20]), .A0(1'b0), .B0(1'b0), .out(p[21]));

    // ------------------------------------------------------------------
    // 4) exponent: E = e_a + e_b + p21 (6 bit),  r = E - 15 = E + 17   20 cells
    // ------------------------------------------------------------------
    wire [5:0] E;
    wire [5:0] ec;                       // exponent ripple carries
    wire       g3;                       // E0 & E1 & E2
    wire [4:1] r;                        // r[0] = ~E0 is folded into its flop

    assign ec[0] = p[21];
    generate
        for (i = 0; i < 5; i = i + 1) begin : g_exp
            fa3 u_fa (.x(a[10+i]), .y(b[10+i]), .z(ec[i]), .s(E[i]), .co(ec[i+1]));
        end
    endgenerate
    assign E[5] = ec[5];

    c2 u_g3 (.D00(1'b0), .D01(E[2]), .D10(1'b0), .D11(1'b0),
             .A1(1'b0), .B1(1'b0), .A0(E[0]), .B0(E[1]), .out(g3));
    c2 u_r1 (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),          // E1 ^ E0
             .A1(E[1]), .B1(1'b0), .A0(E[0]), .B0(1'b1), .out(r[1]));
    c2 u_r2 (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),          // E2 ^ E1E0
             .A1(E[2]), .B1(1'b0), .A0(E[1]), .B0(E[0]), .out(r[2]));
    c2 u_r3 (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),          // E3 ^ E2E1E0
             .A1(E[3]), .B1(1'b0), .A0(g3),   .B0(1'b1), .out(r[3]));
    c2 u_r4 (.D00(1'b1), .D01(1'b0), .D10(1'b0), .D11(1'b1),          // ~(E4 ^ E3E2E1E0)
             .A1(E[4]), .B1(1'b0), .A0(E[3]), .B0(g3),   .out(r[4]));

    // ------------------------------------------------------------------
    // 5) zero / underflow / overflow                                7 cells
    //    zero  : e_a == 0 or e_b == 0  (subnormals are zero)
    //    unf   : E < 16   = ~(E5 | E4)
    //    ovf   : E >= 46  = E5 & X,  X = E4 | E3&E2&E1
    //    kill_e (exponent -> 0)  = zero | unf
    //    kill_m (mantissa -> 0)  = zero | unf | ovf
    //    zero/unf and ovf can never be 1 together.
    // ------------------------------------------------------------------
    wire w_a, w_b, nz_a, nz_b, kill_e, X, kill_m;

    c1 u_w_a  (.S0(a[10]), .S1(a[11]), .SB(1'b0), .B1(1'b1), .B0(1'b1),   // OR4
               .SA(a[12]), .A1(1'b1), .A0(a[13]), .f(w_a));
    c2 u_nz_a (.D00(1'b0), .D01(1'b0), .D10(1'b1), .D11(1'b1),            // OR5
               .A1(w_a), .B1(a[14]), .A0(1'b0), .B0(1'b0), .out(nz_a));
    c1 u_w_b  (.S0(b[10]), .S1(b[11]), .SB(1'b0), .B1(1'b1), .B0(1'b1),
               .SA(b[12]), .A1(1'b1), .A0(b[13]), .f(w_b));
    c2 u_nz_b (.D00(1'b0), .D01(1'b0), .D10(1'b1), .D11(1'b1),
               .A1(w_b), .B1(b[14]), .A0(1'b0), .B0(1'b0), .out(nz_b));
    c2 u_kill_e (.D00(1'b1), .D01(1'b1), .D10(1'b1), .D11(1'b0),
                 .A1(E[5]), .B1(E[4]), .A0(nz_a), .B0(nz_b), .out(kill_e));
    c2 u_X    (.D00(1'b0), .D01(E[1]), .D10(1'b1), .D11(1'b1),
               .A1(E[4]), .B1(1'b0), .A0(E[3]), .B0(E[2]), .out(X));
    c1 u_kill_m (.S0(kill_e), .S1(1'b0), .SB(1'b0), .B1(1'b1), .B0(1'b1),  // kill_e | E5&X
                 .SA(E[5]), .A1(X), .A0(1'b0), .f(kill_m));

    // ------------------------------------------------------------------
    // 6) output registers (s2 = 4:1 mux + flop)                    17 cells
    // ------------------------------------------------------------------
    generate   // mantissa: kill_m ? 0 : (p21 ? p[i+11] : p[i+10])
        for (i = 0; i < 10; i = i + 1) begin : g_frac
            s2 u_q (.D00(p[i+10]), .D01(p[i+11]), .D10(1'b0), .D11(1'b0),
                    .A1(kill_m), .B1(1'b0), .A0(p[21]), .B0(1'b1),
                    .clr(rst), .clk(clk), .out(result[i]));
        end
    endgenerate

    // exponent bit 0 : selects (kill_e | E0, ovf) -> kill ? 0 : ovf ? 1 : ~E0
    s2 u_q10 (.D00(1'b1), .D01(1'b1), .D10(1'b0), .D11(1'b1),
              .A1(kill_e), .B1(E[0]), .A0(E[5]), .B0(X),
              .clr(rst), .clk(clk), .out(result[10]));

    generate   // exponent bits 1..4 : kill_e ? 0 : ovf ? 1 : r[i]
        for (i = 1; i < 5; i = i + 1) begin : g_exp_q
            s2 u_q (.D00(r[i]), .D01(1'b1), .D10(1'b0), .D11(1'b0),
                    .A1(kill_e), .B1(1'b0), .A0(E[5]), .B0(X),
                    .clr(rst), .clk(clk), .out(result[10+i]));
        end
    endgenerate

    // sign : a15 ^ b15
    s2 u_q15 (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
              .A1(a[15]), .B1(1'b0), .A0(b[15]), .B0(1'b1),
              .clr(rst), .clk(clk), .out(result[15]));

    // valid
    s1 u_qv  (.D00(valid_in), .D01(1'b0), .D10(1'b0), .D11(1'b0),
              .A1(1'b0), .B1(1'b0), .A0(1'b0),
              .clr(rst), .clk(clk), .out(valid_out));

endmodule


// ============================================================================
// fa3 : full adder made of 3 c2 cells
//   t  = x ^ y          (c2: s1 = y, s0 = x, D = 0110)
//   s  = t ^ z          (c2: s1 = t, s0 = z, D = 0110)
//   co = maj(x, y, z)   (c2: s1 = y, s0 = x, D = 0 z z 1)
// ============================================================================
module fa3 (input wire x, y, z, output wire s, co);
    wire t;
    c2 u_t  (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
             .A1(y), .B1(1'b0), .A0(x), .B0(1'b1), .out(t));
    c2 u_s  (.D00(1'b0), .D01(1'b1), .D10(1'b1), .D11(1'b0),
             .A1(t), .B1(1'b0), .A0(z), .B0(1'b1), .out(s));
    c2 u_co (.D00(1'b0), .D01(z), .D10(z), .D11(1'b1),
             .A1(y), .B1(1'b0), .A0(x), .B0(1'b1), .out(co));
endmodule
