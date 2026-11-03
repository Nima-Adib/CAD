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
