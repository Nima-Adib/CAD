// ============================================================================
// Module      : layer2_regfile  (Step 6.1 of 05_plan.md)
// Description : 18 x 16-bit register file (as-built layout):
//                 rf[0..7]  : the 8 layer-1 ReLU activations; they stay put
//                 and are re-read through rd_addr as the layer-2 multiplier
//                 operands for every digit.
//                 rf[8..17] : the 10 layer-2 logits; digit d lands in
//                 rf[8+d], written directly from the raw FP16 adder output.
//                 The write range (8..17) never overlaps the read range
//                 (0..7), so no staging array / deferred transfer needed.
//               Write is synchronous, read (rd_data) is asynchronous, and
//               all_outputs exposes the 10 LOGITS only: digit d at slices
//               [159-16d -: 16] (digit 0 = rf[8] at [159:144]).
//               argmax uses a monotonic key (sign-magnitude linearized) and a
//               strict '>' chain, so equal logits resolve to the lowest index.
// ============================================================================
`timescale 1ns/1ps

module layer2_regfile (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [4:0]  wr_addr,          // 0..7 = L1, 8..17 = L2
    input  wire [15:0] wr_data,
    input  wire [4:0]  rd_addr,          // operand reads target rf[0..7]
    output wire [15:0] rd_data,          // asynchronous read
    output wire [159:0] all_outputs      // {rf[8],rf[9],...}: digit d = [159-16d -: 16]
);

    reg [15:0] rf [0:17];
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 18; i = i + 1) rf[i] <= 16'h0000;
        end else if (wr_en) begin
            rf[wr_addr] <= wr_data;
        end
    end

    assign rd_data     = rf[rd_addr];
    assign all_outputs = {rf[8], rf[9], rf[10], rf[11], rf[12],
                          rf[13], rf[14], rf[15], rf[16], rf[17]};

endmodule
