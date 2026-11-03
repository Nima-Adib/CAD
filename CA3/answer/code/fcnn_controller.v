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
