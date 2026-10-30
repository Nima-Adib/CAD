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
