// ============================================================================
// Module      : relu_unit  (Step 3.1 of 05_plan.md)
// Description : ReLU applied to the layer-1 neuron output only (spec Q4):
//               data_out = max(data_in, 0) for IEEE 754 half precision.
//               Combinational: negative (sign bit set) -> +0.
// ============================================================================
`timescale 1ns/1ps

module relu_unit (
    input  wire [15:0] data_in,
    output wire [15:0] data_out
);
    assign data_out = data_in[15] ? 16'h0000 : data_in;
endmodule
