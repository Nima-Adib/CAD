// ============================================================================
// Module      : fcnn_controller  (gate-level, Actel cells only)
// Description : Hand-synthesised version of fcnn_controller.v. Same ports and
//               the same cycle-by-cycle output behaviour as the RTL; built only
//               from c1 / s2 cells (directly or through the one-cell wrappers in
//               actel_gates.v). No logic operator is used in this file.
//
//               State encoding is unchanged (4-bit binary):
//                 0 IDLE      1 L1_REQ    2 L1_WAIT   3 L1_RUN
//                 4 L1_TAIL   5 L1_BIAS   6 L1_STORE  7 L2_REQ
//                 8 L2_WAIT   9 L2_RUN0  10 L2_RUN1  11 L2_TAIL
//                12 L2_BIAS  13 L2_STAGE 14 DONE     (15 is unreachable)
//
//  Optimisations relative to the RTL (none of them changes any output):
//   * `side` is not stored: it is 0 in L2_WAIT and 1 in L2_RUN0, the only two
//     states that read it, so "side == 0" is just "state == L2_WAIT".
//   * `j` (L1 neuron) and `d` (L2 digit) are never needed at the same time, so
//     one 4-bit counter n holds both: n = j in layer 1 and n = d in layer 2.
//     It counts 0..7 (wrapping at L1_STORE when j == 7, which is the
//     RTL's d <= 0) and then 0..9 (wrapping at L2_STAGE when d == 9).
//   * beat is always 0 outside the three RUN states, so its update is a plain
//     wrap-at-6 counter that only runs in RUN states and is cleared on
//     beat == 6 / L2 side-1 arrival / rst.
//   * batch is cleared in L1_REQ (it is 0 in L1_REQ in the RTL as well);
//     add_cnt is cleared in both REQ states, like the RTL.
//   * sram_w_addr = 112*j + (batch+1) is built as {7*j + t, low nibble}, where
//     t is bits [6:4] of the issued in_addr, so only a 6-bit adder is needed.
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
    output wire [9:0]  sram_w_addr,
    output wire        sram_w_read_en,
    output wire [6:0]  sram_in_addr,
    output wire        sram_in_read_en,
    // control outputs: multiplier / ping-pong
    output wire        mult_en,
    output wire [2:0]  mult_elem_sel,
    output wire        buf_wr_en,
    output wire        buf_rd_en,
    output wire        buf_swap,
    // control outputs: adder / register file
    output wire        add_start,
    output wire        add_bias_sel,
    output wire        accum_clr,
    output wire        layer_sel,
    output wire [4:0]  bias_addr,
    output wire        l2_wr_en,
    output wire [3:0]  l2_wr_addr,
    output wire [3:0]  l2_rd_addr,
    // status outputs
    output wire        done
);

    // ------------------------------------------------------------------
    // registers
    // ------------------------------------------------------------------
    wire [3:0] q;        // state
    wire [3:0] n;        // shared j / d counter
    wire [6:0] b;        // batch
    wire [2:0] bt;       // beat
    wire [9:0] c;        // add_cnt
    wire       last;     // last_arr

    wire wv = sram_w_valid;
    wire iv = sram_in_valid;

    // ------------------------------------------------------------------
    // state decodes
    // ------------------------------------------------------------------
    wire R1, R2, W1, RUN0, RUN1, TAIL2, STAGE, layer;
    g_nor3_and d_r1   (q[1], q[2], q[3], q[0], R1);      // 0001
    g_and3     d_r2   (q[2], q[1], q[0], R2);            // 0111
    g_nor3_and d_w1   (q[0], q[2], q[3], q[1], W1);      // 0010
    g_nor2_and d_run1 (q[2], q[3], q[0], q[1], RUN1);    // 0011
    g_nor2_and d_run0 (q[1], q[2], q[0], q[3], RUN0);    // 1001
    g_and3     d_tl2  (q[0], q[1], q[3], TAIL2);         // 1011
    g_and3     d_stg  (q[0], q[2], q[3], STAGE);         // 1101
    g_and3     d_done (q[3], q[2], q[1], done);          // 1110
    g_or       d_lay  (q[3], R2, layer);                 // 7..14
    assign layer_sel = layer;

    // ------------------------------------------------------------------
    // simple control outputs
    // ------------------------------------------------------------------
    // mult_en : states 3, 9, 10
    c1 o_mul (.A0(1'b0), .A1(q[3]), .SA(q[1]), .B0(RUN0), .B1(RUN1), .SB(q[1]),
              .S0(q[0]), .S1(q[2]), .f(mult_en));
    assign buf_wr_en = mult_en;
    // buf_rd_en / buf_swap : states 3, 4, 9, 10, 11
    c1 o_brd (.A0(q[2]), .A1(1'b0), .SA(q[3]), .B0(TAIL2), .B1(1'b1), .SB(mult_en),
              .S0(q[0]), .S1(q[1]), .f(buf_rd_en));
    assign buf_swap = buf_rd_en;
    // add_start / add_bias_sel : states 5, 12
    c1 o_ads (.A0(1'b0), .A1(q[3]), .SA(q[2]), .B0(q[2]), .B1(1'b0), .SB(layer),
              .S0(q[0]), .S1(done), .f(add_start));
    assign add_bias_sel = add_start;
    // l2_wr_en : states 6, 13
    c1 o_l2w (.A0(STAGE), .A1(1'b0), .SA(1'b0), .B0(q[2]), .B1(1'b0), .SB(layer),
              .S0(1'b0), .S1(q[1]), .f(l2_wr_en));
    // accum_clr : states 1, 7
    g_or o_acl (R1, R2, accum_clr);

    // bias_addr = BIAS1 ? j : BIAS2 ? 8 + d : 0
    g_and   o_ba0 (add_start, n[0], bias_addr[0]);
    g_and   o_ba1 (add_start, n[1], bias_addr[1]);
    g_and   o_ba2 (add_start, n[2], bias_addr[2]);
    g_andn2 o_ba3 (n[3], add_start, q[3], bias_addr[3]);
    g_and   o_ba4 (add_start, n[3], bias_addr[4]);
    // l2_wr_addr = STORE1 ? j : STAGE ? d : 0      (n[3] is 0 in layer 1)
    g_and   o_wa0 (l2_wr_en, n[0], l2_wr_addr[0]);
    g_and   o_wa1 (l2_wr_en, n[1], l2_wr_addr[1]);
    g_and   o_wa2 (l2_wr_en, n[2], l2_wr_addr[2]);
    g_and   o_wa3 (l2_wr_en, n[3], l2_wr_addr[3]);
    // l2_rd_addr = RUN0 ? {0, beat} : 7
    g_mux2  o_ra0 (1'b1, bt[0], RUN0, l2_rd_addr[0]);
    g_mux2  o_ra1 (1'b1, bt[1], RUN0, l2_rd_addr[1]);
    g_mux2  o_ra2 (1'b1, bt[2], RUN0, l2_rd_addr[2]);
    assign l2_rd_addr[3] = 1'b0;
    assign mult_elem_sel = bt;

    // ------------------------------------------------------------------
    // condition signals
    // ------------------------------------------------------------------
    // arrivals
    wire P1, P2, inc_en, I2, kb;
    g_nor2_and a_p1 (q[2], q[3], q[1], wv, P1);   // {L1_WAIT, L1_RUN} & w_valid
    g_and      a_ie (P1, iv, inc_en);             // ... & in_valid  (= L1 arrival)
    g_nor2_and a_p2 (q[1], q[2], q[3], wv, P2);   // {L2_WAIT, L2_RUN0} & w_valid
    g_andn     a_i2 (q[0], P2, I2);               // L2_WAIT & arrival -> issue side 1
    g_and      a_kb (P2, q[0], kb);               // L2_RUN0 & arrival (side 1 landed)

    // beat == 6 and the RUN exit condition
    wire beat6, LB;
    g_and b_b6 (bt[2], bt[1], beat6);
    g_and b_lb (last, beat6, LB);

    // j == 7 (layer 1) and d == 9 (layer 2) on the shared counter
    wire Jl, Dl;
    g_and3 n_jl (n[2], n[1], n[0], Jl);
    g_and  n_dl (n[3], n[0], Dl);

    // add_cnt == 784 (11_0001_0000)
    wire e784, ka, kz0, kz;
    g_and3     k_a  (c[9], c[8], c[4], ka);
    g_nor3     k_z0 (c[0], c[1], c[2], kz0);
    g_nor3_and k_z  (c[5], c[6], c[7], kz0, kz);
    g_andn2    k_eq (c[3], ka, kz, e784);
    // add_cnt != 14 (00_0000_1110)
    wire ne14, ko57, kh, kq;
    g_or3      m_o  (c[5], c[6], c[7], ko57);
    g_or4      m_h  (c[9], c[8], c[4], ko57, kh);
    g_and3     m_q  (c[1], c[2], c[3], kq);
    g_or2n     m_ne (c[0], kh, kq, ne14);

    // ------------------------------------------------------------------
    // next-state logic (one s2 per state bit, synchronous rst)
    // ------------------------------------------------------------------
    // bit 3
    s2 st3 (.D00(layer), .D01(Dl), .D10(1'b0), .D11(1'b0),
            .A1(rst), .B1(done), .A0(1'b1), .B0(STAGE),
            .clr(rst), .clk(clk), .out(q[3]));
    // bit 2
    wire x2a, x2b;
    c1 n2a (.A0(1'b0), .A1(LB), .SA(q[0]), .B0(q[2]), .B1(Jl), .SB(q[1]),
            .S0(q[2]), .S1(R1), .f(x2a));
    c1 n2b (.A0(q[0]), .A1(1'b0), .SA(ne14), .B0(q[2]), .B1(1'b0), .SB(q[1]),
            .S0(q[2]), .S1(RUN0), .f(x2b));
    s2 st2 (.D00(x2a), .D01(x2b), .D10(1'b0), .D11(1'b0),
            .A1(rst), .B1(1'b0), .A0(1'b1), .B0(layer),
            .clr(rst), .clk(clk), .out(q[2]));
    // bit 1
    wire x1a, x1b;
    c1 n1a (.A0(q[0]), .A1(wv), .SA(RUN0), .B0(1'b1), .B1(Jl), .SB(q[2]),
            .S0(1'b0), .S1(q[1]), .f(x1a));
    c1 n1b (.A0(1'b1), .A1(1'b0), .SA(LB), .B0(1'b0), .B1(q[3]), .SB(ne14),
            .S0(1'b0), .S1(layer), .f(x1b));
    s2 st1 (.D00(x1a), .D01(x1b), .D10(1'b0), .D11(1'b0),
            .A1(rst), .B1(done), .A0(q[0]), .B0(q[1]),
            .clr(rst), .clk(clk), .out(q[1]));
    // bit 0
    wire g1, g2, x0a, x0b;
    c1 n0g1 (.A0(start), .A1(e784), .SA(q[2]), .B0(q[1]), .B1(inc_en), .SB(W1),
             .S0(q[0]), .S1(q[1]), .f(g1));
    g_nor2_and n0a (layer, LB, g1, 1'b1, x0a);
    c1 n0g2 (.A0(wv), .A1(LB), .SA(q[1]), .B0(1'b1), .B1(q[2]), .SB(wv),
             .S0(q[0]), .S1(q[2]), .f(g2));
    c1 n0b (.A0(g2), .A1(ne14), .SA(TAIL2), .B0(1'b1), .B1(1'b0), .SB(Dl),
            .S0(STAGE), .S1(1'b0), .f(x0b));
    s2 st0 (.D00(x0a), .D01(x0b), .D10(1'b0), .D11(1'b0),
            .A1(rst), .B1(done), .A0(1'b1), .B0(q[3]),
            .clr(rst), .clk(clk), .out(q[0]));

    // ------------------------------------------------------------------
    // shared j / d counter  (advances in L1_STORE and L2_STAGE)
    // ------------------------------------------------------------------
    wire x01, t1s, w3;
    g_andn j_x01 (n[3], n[0], x01);               // n0 & ~n3  (no carry out of 9)
    g_and  j_t1  (l2_wr_en, x01, t1s);
    g_mux2 j_w3  (Jl, n[0], n[3], w3);            // n == 7 or n == 9
    g_tff  j_f0 (clk, rst, l2_wr_en, 1'b1, 1'b1, n[0]);
    g_tff  j_f1 (clk, rst, t1s,      1'b1, 1'b1, n[1]);
    g_tff  j_f2 (clk, rst, t1s,      n[1], 1'b1, n[2]);
    g_tff  j_f3 (clk, rst, STAGE,    w3,   1'b1, n[3]);

    // ------------------------------------------------------------------
    // beat (0..6, runs only in RUN states)
    // ------------------------------------------------------------------
    wire nclrb;
    g_nor  bt_cl (beat6, kb, nclrb);
    g_tff  bt_f0 (clk, rst, mult_en, 1'b1,  nclrb, bt[0]);
    g_tff  bt_f1 (clk, rst, bt[0],   1'b1,  nclrb, bt[1]);
    g_tff  bt_f2 (clk, rst, bt[0],   bt[1], nclrb, bt[2]);

    // ------------------------------------------------------------------
    // batch counter, in_addr = batch + 1 (masked by the issue condition)
    // ------------------------------------------------------------------
    wire p2, p3, p4, p5, p6, bz, I1, nclr_b;
    g_and   bp2 (b[0], b[1], p2);                 // prefix ANDs b[0..i-1]
    g_and   bp3 (p2, b[2], p3);
    g_and   bp4 (p3, b[3], p4);
    g_and   bp5 (p4, b[4], p5);
    g_and   bp6 (p5, b[5], p6);
    g_andn2 bzz (b[4], b[5], b[6], bz);           // with p4 : batch == 111
    g_nand_and bi1 (p4, bz, inc_en, I1);          // issue next L1 row
    g_not   bcl (R1, nclr_b);
    g_tff  bf0 (clk, rst, inc_en, 1'b1, nclr_b, b[0]);
    g_tff  bf1 (clk, rst, inc_en, b[0], nclr_b, b[1]);
    g_tff  bf2 (clk, rst, inc_en, p2,   nclr_b, b[2]);
    g_tff  bf3 (clk, rst, inc_en, p3,   nclr_b, b[3]);
    g_tff  bf4 (clk, rst, inc_en, p4,   nclr_b, b[4]);
    g_tff  bf5 (clk, rst, inc_en, p5,   nclr_b, b[5]);
    g_tff  bf6 (clk, rst, inc_en, p6,   nclr_b, b[6]);

    wire [6:0] ia;
    g_andn ia0 (b[0], I1, ia[0]);
    g_xand ia1 (b[1], b[0], I1, ia[1]);
    g_xand ia2 (b[2], p2,   I1, ia[2]);
    g_xand ia3 (b[3], p3,   I1, ia[3]);
    g_xand ia4 (b[4], p4,   I1, ia[4]);
    g_xand ia5 (b[5], p5,   I1, ia[5]);
    g_xand ia6 (b[6], p6,   I1, ia[6]);
    assign sram_in_addr = ia;

    // last_arr : set by the arrival of L1 row 111, or by the L2 side-1 arrival
    s2 la (.D00(last), .D01(last), .D10(kb), .D11(1'b1),
           .A1(inc_en), .B1(kb), .A0(p4), .B0(bz),
       .clr(rst), .clk(clk), .out(last));

    // ------------------------------------------------------------------
    // read enables
    // ------------------------------------------------------------------
    wire E1, E2;
    g_or  re1 (R1, I1, E1);                       // L1 request / issue
    g_or  re2 (R2, I2, E2);                       // L2 request / issue
    g_or3 rew (I1, I2, accum_clr, sram_w_read_en);
    assign sram_in_read_en = E1;

    // ------------------------------------------------------------------
    // add_cnt (10-bit, cleared in REQ states)
    // ------------------------------------------------------------------
    wire ncl_c, e2c, e4c, e6c, e8c;
    g_nor  ccl (R1, R2, ncl_c);
    g_and3 ce2 (add_done, c[0], c[1], e2c);
    g_and3 ce4 (e2c, c[2], c[3], e4c);
    g_and3 ce6 (e4c, c[4], c[5], e6c);
    g_and3 ce8 (e6c, c[6], c[7], e8c);
    g_tff cf0 (clk, rst, add_done, 1'b1, ncl_c, c[0]);
    g_tff cf1 (clk, rst, add_done, c[0], ncl_c, c[1]);
    g_tff cf2 (clk, rst, e2c,      1'b1, ncl_c, c[2]);
    g_tff cf3 (clk, rst, e2c,      c[2], ncl_c, c[3]);
    g_tff cf4 (clk, rst, e4c,      1'b1, ncl_c, c[4]);
    g_tff cf5 (clk, rst, e4c,      c[4], ncl_c, c[5]);
    g_tff cf6 (clk, rst, e6c,      1'b1, ncl_c, c[6]);
    g_tff cf7 (clk, rst, e6c,      c[6], ncl_c, c[7]);
    g_tff cf8 (clk, rst, e8c,      1'b1, ncl_c, c[8]);
    g_tff cf9 (clk, rst, e8c,      c[8], ncl_c, c[9]);

    // ------------------------------------------------------------------
    // weight address
    //   L1 : 112*j + ia   = { 7*j + ia[6:4] , ia[3:0] }
    //   L2 : 896 + 2*d (+1 for side 1)
    // ------------------------------------------------------------------
    // A = E1 ? 7*j : 0, with A[0] also carrying d[3] for the L2 address bit 4
    wire [5:0] A;
    g_mmux2   wa0 (E1, n[0], E2, n[3], layer, A[0]);
    g_xand    wa1 (n[0], n[1], E1, A[1]);
    g_xand_o  wa2 (n[1], n[0], n[2], E1, A[2]);
    g_or_andn wa3 (n[1], n[2], n[0], E1, A[3]);
    c1        wa4 (.A0(1'b0), .A1(E1), .SA(n[2]), .B0(1'b0), .B1(A[0]), .SB(n[1]),
                   .S0(n[1]), .S1(n[0]), .f(A[4]));
    g_or_and2 wa5 (n[1], n[0], n[2], E1, A[5]);

    // 6-bit add  A + ia[6:4]
    wire k1, k2, k3, k4, k5, s1p, s2p;
    g_xor    ad0 (A[0], ia[4], sram_w_addr[4]);
    g_and    ac1 (A[0], ia[4], k1);
    g_xor    ap1 (A[1], ia[5], s1p);
    g_xor    ad1 (s1p, k1, sram_w_addr[5]);
    g_mux2   ac2 (A[1], k1, s1p, k2);
    g_xor    ap2 (A[2], ia[6], s2p);
    g_xor    ad2 (s2p, k2, sram_w_addr[6]);
    // carry into bit 7 : the 10-bit RTL sum keeps batch+1 = 128 (batch == 127)
    wire co7;
    g_and3   ac7 (I1, p6, b[6], co7);
    c1       ac3 (.A0(A[2]), .A1(k2), .SA(s2p), .B0(1'b1), .B1(1'b1), .SB(1'b0),
                  .S0(co7), .S1(1'b0), .f(k3));     // k3 = co7 | (s2p ? k2 : A2)
    g_xor_or ad3 (A[3], k3, E2, sram_w_addr[7]);  // bits 7..9 are 1 in L2
    g_and    ac4 (A[3], k3, k4);
    g_xor_or ad4 (A[4], k4, E2, sram_w_addr[8]);
    g_and    ac5 (A[4], k4, k5);
    g_xor_or ad5 (A[5], k5, E2, sram_w_addr[9]);

    // low nibble
    g_or ad_l0 (ia[0], I2, sram_w_addr[0]);
    g_ao ad_l1 (ia[1], E2, n[0], sram_w_addr[1]);
    g_ao ad_l2 (ia[2], E2, n[1], sram_w_addr[2]);
    g_ao ad_l3 (ia[3], E2, n[2], sram_w_addr[3]);

endmodule
