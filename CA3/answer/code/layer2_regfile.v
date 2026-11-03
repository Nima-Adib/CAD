// ============================================================================
// Module      : layer2_regfile  (CA2 phase 2 - structural)
// Description : 18 x 16-bit register file. rf[0..7] = L1 ReLU activations,
//               rf[8..17] = L2 logits (digit d in rf[8+d]).
//               Synchronous write (reset has priority), asynchronous read.
//
// Synthesis notes (every point removes cells, behavior is unchanged):
//   * one s2 cell per stored bit: its internal 4:1 mux gives
//        hold / write / reset in a single cell:
//           S1 = rst            S0 = sel_hi & sel_lo
//           (S1,S0)=00 -> q (hold)   01 -> d (write)   1x -> 0 (reset)
//   * write-enable decode is split in two predecoded groups
//        sel_lo[k] = (wr_addr[1:0] == k)           (4 lines)
//        sel_hi[m] = wr_en & (wr_addr[4:2] == m)   (5 lines)
//     rf[4m+k] is written when sel_hi[m] & sel_lo[k]; the AND is the free
//     S0 = A0 & B0 gate inside each s2, so no per-register decoder exists.
//   * rf[0..7][15] is a constant 0: those registers are only ever written
//     with ReLU output (sign bit always 0) -> 8 flip-flops saved.
//   * the controller only reads rf[0..7] (rd_addr 0..7) -> 8:1 read mux
//     on 15 bits (bit 15 is 0), built from 2 x g_mux4 + 1 x g_mux2 per bit.
//   * the array is exported as 'rf' (wire array) so the testbench can read
//     uut.u_dp.u_rf.rf[i+8].
// Requires    : actel_gates.v, cells c1 / s2 (modules.v; s2 ports: ... clr, clk, out)
// ============================================================================
`timescale 1ns/1ps

// y = ~(a | b) & c & d      (one c1: S0|S1 forces 0, else SA ? d : 0)
module g_nor2_and2 (input a, b, c, d, output y);
    c1 u (.A0(1'b0), .A1(d), .SA(c), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(a), .S1(b), .f(y));
endmodule

// One stored bit (1 x s2 = 13 gates)
module rf_bit (
    input  wire clk,
    input  wire rst,
    input  wire sel_hi,
    input  wire sel_lo,
    input  wire d,
    output wire q
);
    s2 u_ff (.D00(q),    .D01(d),
             .D10(1'b0), .D11(1'b0),
             .A1(rst),   .B1(rst),
             .A0(sel_hi), .B0(sel_lo),
             .clr(1'b0), .clk(clk), .out(q));
endmodule

// Write-enable predecoder (10 c1 = 100 gates)
module rf_wr_decode (
    input  wire       wr_en,
    input  wire [4:0] a,
    output wire [3:0] lo,      // lo[k] = (a[1:0] == k)
    output wire [4:0] hi       // hi[m] = wr_en & (a[4:2] == m)
);
    g_nor  u_lo0 (.a(a[1]), .b(a[0]), .y(lo[0]));
    g_andn u_lo1 (.a(a[1]), .b(a[0]), .y(lo[1]));
    g_andn u_lo2 (.a(a[0]), .b(a[1]), .y(lo[2]));
    g_and  u_lo3 (.a(a[1]), .b(a[0]), .y(lo[3]));

    g_nor3_and  u_hi0 (.a(a[4]), .b(a[3]), .c(a[2]), .d(wr_en), .y(hi[0]));
    g_nor2_and2 u_hi1 (.a(a[4]), .b(a[3]), .c(a[2]), .d(wr_en), .y(hi[1]));
    g_nor2_and2 u_hi2 (.a(a[4]), .b(a[2]), .c(a[3]), .d(wr_en), .y(hi[2]));
    wire t3;
    g_and3 u_t3  (.a(wr_en), .b(a[3]), .c(a[2]), .y(t3));
    g_andn u_hi3 (.a(a[4]), .b(t3), .y(hi[3]));
    g_nor2_and2 u_hi4 (.a(a[3]), .b(a[2]), .c(a[4]), .d(wr_en), .y(hi[4]));
endmodule

// 8:1 read mux for one bit (3 c1 = 30 gates)
module rf_rd_mux8 (
    input  wire [7:0] d,
    input  wire [2:0] s,
    output wire       y
);
    wire lo, hi;
    g_mux4 u_lo (.d0(d[0]), .d1(d[1]), .d2(d[2]), .d3(d[3]), .s1(s[1]), .s0(s[0]), .y(lo));
    g_mux4 u_hi (.d0(d[4]), .d1(d[5]), .d2(d[6]), .d3(d[7]), .s1(s[1]), .s0(s[0]), .y(hi));
    g_mux2 u_fn (.a0(lo), .a1(hi), .s(s[2]), .y(y));
endmodule

module layer2_regfile (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [4:0]  wr_addr,          // 0..7 = L1, 8..17 = L2
    input  wire [15:0] wr_data,
    input  wire [4:0]  rd_addr,          // operand reads target rf[0..7] (bits [2:0] used)
    output wire [15:0] rd_data           // asynchronous read
);

    wire [15:0] rf [0:17];               // exported for the testbench

    wire [3:0] sel_lo;
    wire [4:0] sel_hi;
    rf_wr_decode u_dec (.wr_en(wr_en), .a(wr_addr), .lo(sel_lo), .hi(sel_hi));

    genvar e, b;
    generate
        for (e = 0; e < 18; e = e + 1) begin : g_reg
            wire [15:0] q;
            for (b = 0; b < 16; b = b + 1) begin : g_bit
                if (e < 8 && b == 15) begin : g_zero
                    assign q[b] = 1'b0;          // L1 values are never negative
                end else begin : g_ff
                    rf_bit u_bit (.clk(clk), .rst(rst),
                                  .sel_hi(sel_hi[e / 4]), .sel_lo(sel_lo[e % 4]),
                                  .d(wr_data[b]), .q(q[b]));
                end
            end
            assign rf[e] = q;
        end
    endgenerate

    // asynchronous read of rf[0..7]
    generate
        for (b = 0; b < 15; b = b + 1) begin : g_rd
            rf_rd_mux8 u_mux (.d({rf[7][b], rf[6][b], rf[5][b], rf[4][b],
                                  rf[3][b], rf[2][b], rf[1][b], rf[0][b]}),
                              .s(rd_addr[2:0]), .y(rd_data[b]));
        end
    endgenerate
    assign rd_data[15] = 1'b0;

endmodule