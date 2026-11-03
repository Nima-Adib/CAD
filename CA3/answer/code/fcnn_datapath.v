// ============================================================================
// Module      : fcnn_datapath  (CA2 phase 2 - structural)
// Description : Same datapath as phase 1 (SRAM models, row registers, the single
//               multiplier, ping-pong buffer, the single adder, ReLU, 18-entry
//               register file, bias ROM). Instance names (u_wmem, u_imem, u_mul,
//               u_pp, u_add, u_relu, u_rf) and ports are unchanged.
//
//               Only Actel gates (actel_gates.v) and s2 flip-flops are used.
//               The SRAM models and the bias ROM are the phase-1 behavioral
//               memories (not synthesized, not counted).
//
// Synthesis changes (behavior identical, checked with a cycle model of the
// controller: operands seen by the multiplier match the phase-1 datapath on
// every multiplier-enabled cycle):
//   * ROW REGISTERS are parallel-load SHIFT registers (row_shift7):
//        valid  -> load all 7 lanes      mult_en -> shift by one lane
//     the multiplier reads lane 0 only. This replaces the two 7:1 operand
//     muxes (w_reg[beat], x_reg[beat]): the s2 cell already contains the
//     4:1 mux (hold / load / shift), so the muxes cost nothing here.
//     (the controller's beat counter advances exactly once per RUN cycle and
//      the next row always arrives at beat 6, so lane 0 == lane[beat].)
//   * adder-kick / write-window / rf-address logic uses single c1 gates.
//   * rd_hit = rd_en & (~empty | (swap & full)) in 2 cells
//     (original: (rd_en&~empty) | (swap&full&empty&rd_en), same function).
// ============================================================================
`timescale 1ns/1ps

// plain D flip-flop with asynchronous reset (1 x s2 = 13 gates)
module dp_dff (
    input  wire clk,
    input  wire rst,
    input  wire d,
    output wire q
);
    s2 u_ff (.D00(d), .D01(d), .D10(d), .D11(d),
             .A1(1'b0), .B1(1'b0), .A0(1'b0), .B0(1'b0),
             .clr(rst), .clk(clk), .out(q));
endmodule

// 7 x 16-bit row register: parallel load (priority) / shift toward lane 0 / hold.
// d and q use the SRAM layout: lane k = [111-16k -: 16]; q0 = lane 0 (current operand).
module row_shift7 (
    input  wire         clk,
    input  wire         rst,
    input  wire         load,       // sram data_valid
    input  wire         shift,      // multiplier enable
    input  wire [111:0] d,
    output wire [15:0]  q0
);
    wire [111:0] q;
    genvar k, b;
    generate
        for (k = 0; k < 7; k = k + 1) begin : g_lane
            for (b = 0; b < 16; b = b + 1) begin : g_bit
                // (S1,S0) = {shift,load}: 00 hold | 01 load | 10 shift | 11 load
                if (k < 6) begin : g_mid
                    s2 u_ff (.D00(q[96-16*k+b]), .D01(d[96-16*k+b]),
                             .D10(q[80-16*k+b]), .D11(d[96-16*k+b]),
                             .A1(shift), .B1(shift), .A0(load), .B0(load),
                             .clr(rst), .clk(clk), .out(q[96-16*k+b]));
                end else begin : g_last
                    s2 u_ff (.D00(q[96-16*k+b]), .D01(d[96-16*k+b]),
                             .D10(1'b0),         .D11(d[96-16*k+b]),
                             .A1(shift), .B1(shift), .A0(load), .B0(load),
                             .clr(rst), .clk(clk), .out(q[96-16*k+b]));
                end
            end
        end
    endgenerate
    assign q0 = q[111:96];
endmodule

// rd_hit = r & (~e | (s & f))      (2 x c1)
module dp_rd_hit (
    input  wire r,      // buf_rd_en
    input  wire s,      // buf_swap
    input  wire f,      // buf_full
    input  wire e,      // buf_empty
    output wire y
);
    wire rf_;
    g_and u_rf (.a(r), .b(f), .y(rf_));
    // e=0 -> r ;  e=1 -> s ? (r&f) : 0
    c1 u_y (.A0(r), .A1(1'b0), .SA(1'b0),
            .B0(1'b0), .B1(rf_), .SB(s),
            .S0(e), .S1(1'b0), .f(y));
endmodule

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
    input  wire [2:0]   mult_elem_sel,   // (unused: rows are shift registers, lane 0 = beat)
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
    input  wire [3:0]   l2_rd_addr
);

    // ================= internal signals =================
    wire [111:0]  w_row_data, x_row_data;
    wire [15:0]   w_lane0, x_lane0;
    wire [15:0]   rf_rd_data, rf_wr_data;
    wire          rf_wr_en;
    wire [4:0]    rf_wr_addr;
    wire [15:0]   mult_a, mult_b, mult_result;
    wire          pp_bank_sel;
    wire          wr_win;
    wire [15:0]   pp_rd_data;
    wire [15:0]   bias_val, adder_op, accum_q, relu_out;

    // ================= memory models (phase-1 behavioral, not counted) =================
    sram_weights_model u_wmem (.clk(clk), .rst(rst),
        .read_en(sram_w_read_en), .addr({1'b0, sram_w_addr}),
        .data_out(w_row_data), .data_valid(sram_w_valid));
    sram_inputs_model u_imem (.clk(clk), .rst(rst),
        .read_en(sram_in_read_en), .addr(sram_in_addr),
        .data_out(x_row_data), .data_valid(sram_in_valid));

    // ================= row registers (shift registers, lane 0 = current beat) =================
    row_shift7 u_wrow (.clk(clk), .rst(rst), .load(sram_w_valid),  .shift(mult_en),
                       .d(w_row_data), .q0(w_lane0));
    row_shift7 u_xrow (.clk(clk), .rst(rst), .load(sram_in_valid), .shift(mult_en),
                       .d(x_row_data), .q0(x_lane0));

    // ================= register file (async read, 18 entries) =================
    layer2_regfile u_rf (.clk(clk), .rst(rst),
        .wr_en(rf_wr_en), .wr_addr(rf_wr_addr), .wr_data(rf_wr_data),
        .rd_addr({1'b0, l2_rd_addr}), .rd_data(rf_rd_data));

    // ================= the single FP16 multiplier =================
    assign mult_a = w_lane0;
    genvar b;
    generate
        for (b = 0; b < 16; b = b + 1) begin : g_mb
            // mult_b = layer_sel ? rf_rd_data : x operand
            g_mux2 u_mb (.a0(x_lane0[b]), .a1(rf_rd_data[b]), .s(layer_sel), .y(mult_b[b]));
        end
    endgenerate
    fp16_multiplier u_mul (.clk(clk), .rst(rst),
        .valid_in(mult_en), .a(mult_a), .b(mult_b),
        .result(mult_result), .valid_out(mult_valid));

    // ================= ping-pong buffer =================
    // 1-cycle write window: keeps the trailing product of the last beat
    dp_dff u_wwin (.clk(clk), .rst(rst), .d(buf_wr_en), .q(wr_win));
    wire pp_wr_en;
    g_and u_ppwe (.a(mult_valid), .b(wr_win), .y(pp_wr_en));
    ping_pong_buffer u_pp (.clk(clk), .rst(rst),
        .wr_en(pp_wr_en), .wr_data(mult_result),
        .rd_en(buf_rd_en), .swap_req(buf_swap),
        .rd_data(pp_rd_data), .wr_full(buf_full),
        .rd_empty(buf_empty), .bank_select(pp_bank_sel));

    // ================= the single FP16 adder (accumulator) =================
    // rd_hit covers BOTH read kinds: a normal drain beat and the swap-cycle read.
    wire rd_hit, rd_hit_d, adder_kick;
    dp_rd_hit u_rdhit (.r(buf_rd_en), .s(buf_swap), .f(buf_full), .e(buf_empty), .y(rd_hit));
    dp_dff    u_rdhd  (.clk(clk), .rst(rst), .d(rd_hit), .q(rd_hit_d));
    g_or      u_kick  (.a(rd_hit_d), .b(add_start), .y(adder_kick));   // read kicks + bias kick

    generate
        for (b = 0; b < 16; b = b + 1) begin : g_op
            // adder_op = add_bias_sel ? bias_val : pp_rd_data
            g_mux2 u_op (.a0(pp_rd_data[b]), .a1(bias_val[b]), .s(add_bias_sel), .y(adder_op[b]));
        end
    endgenerate
    fp16_adder u_add (.clk(clk), .rst(rst),
        .clr_accum(accum_clr), .start_add(adder_kick),
        .operand_b(adder_op), .add_bias(add_bias_sel),
        .accum_out(accum_q), .add_done(add_done));

    // ================= ReLU (L1 only) =================
    relu_unit u_relu (.data_in(accum_q), .data_out(relu_out));

    // ================= RF write side (direct, no staging) ============
    // L1 STORE : rf[l2_wr_addr]   <= relu(accum)   (rf[0..7])
    // L2 STAGE : rf[l2_wr_addr+8] <= accum         (rf[8..17], raw)
    // l2_wr_addr + 8 (layer_sel=1):  bit3 = ~d3, bit4 = d3 ; layer_sel=0: {0,d}
    assign rf_wr_en = l2_wr_en;
    assign rf_wr_addr[2:0] = l2_wr_addr[2:0];
    g_xor u_wa3 (.a(l2_wr_addr[3]), .b(layer_sel), .y(rf_wr_addr[3]));
    g_and u_wa4 (.a(layer_sel),     .b(l2_wr_addr[3]), .y(rf_wr_addr[4]));
    generate
        for (b = 0; b < 16; b = b + 1) begin : g_wd
            g_mux2 u_wd (.a0(relu_out[b]), .a1(accum_q[b]), .s(layer_sel), .y(rf_wr_data[b]));
        end
    endgenerate

    // ================= bias ROM (phase-1 behavioral memory, not counted) =================
    reg [15:0] bias_rom [0:17];
    initial $readmemh("assets/bias.mem", bias_rom);
    assign bias_val = bias_rom[bias_addr];

endmodule