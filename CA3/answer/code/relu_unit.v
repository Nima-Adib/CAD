// ============================================================================
// Module      : relu_unit  (CA2 phase 2 - structural)
// Description : ReLU for the layer-1 neuron output (IEEE 754 half):
//                 data_out = data_in[15] ? 16'h0000 : data_in
//               i.e. data_out[i] = ~data_in[15] & data_in[i]   (i = 0..14)
//                    data_out[15] = 0 (constant, no cell needed)
//
// Mapping     : one g_andn gate per bit (actel_gates.v):  y = ~a & b
//               with a = sign bit, b = data_in[i]  ->  exactly ONE c1 per bit.
//               Every output bit is a different function and a cell has a
//               single output, so 15 cells is the minimum:
//                 15 x c1 = 15 x 10 = 150 gates.
// Requires    : actel_gates.v (g_andn)
// ============================================================================
`timescale 1ns/1ps

module relu_unit (
    input  wire [15:0] data_in,
    output wire [15:0] data_out
);
    genvar i;
    generate
        for (i = 0; i < 15; i = i + 1) begin : g_relu
            g_andn u_bit (.a(data_in[15]), .b(data_in[i]), .y(data_out[i]));
        end
    endgenerate

    assign data_out[15] = 1'b0;      // result is never negative
endmodule