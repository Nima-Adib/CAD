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
//               Write is synchronous, read (rd_data) is asynchronous.
//               CA2: the all_outputs bus was removed; the testbench reads the
//               logits directly as rf[8+d].
// ============================================================================
`timescale 1ns/1ps

module layer2_regfile (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [4:0]  wr_addr,          // 0..7 = L1, 8..17 = L2
    input  wire [15:0] wr_data,
    input  wire [4:0]  rd_addr,          // operand reads target rf[0..7]
    output wire [15:0] rd_data           // asynchronous read
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

endmodule
