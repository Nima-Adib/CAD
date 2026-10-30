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
