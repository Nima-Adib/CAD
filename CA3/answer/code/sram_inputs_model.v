// ============================================================================
// Module      : sram_inputs_model  (Step 1.2 / Step 7.x of 05_plan.md)
// Description : Behavioral SRAM model of the input activations, 7-cycle
//               latency. Contents: 784 x 16-bit words from assets/input.mem
//               = 112 rows x 7 lanes (the same fixed x for every L1 neuron).
//               Timing identical to sram_weights_model:
//                 read_en high during cycle T -> data_valid high during T+7,
//                 data_out registered at the same posedge; new issues restart
//               the countdown while the current row completes (cnt == 1).
// ============================================================================
`timescale 1ns/1ps

module sram_inputs_model (
    input  wire         clk,
    input  wire         rst,
    input  wire         read_en,
    input  wire [6:0]   addr,           // row 0..111
    output reg  [111:0] data_out,       // 7 lanes, lane 0 on [111:96]
    output reg          data_valid
);

    localparam LATENCY = 3'd6;          // issue -> cnt=6; completes at cnt==1

    reg [15:0]  mem_flat [0:783];
    reg [111:0] rows     [0:111];
    reg [6:0]   lat_addr;
    reg [2:0]   cnt;

    initial begin
        integer w, r, j;
        for (w = 0; w < 784; w = w + 1) mem_flat[w] = 16'h0000;
        $readmemh("assets/input.mem", mem_flat);
        for (r = 0; r < 112; r = r + 1)
            for (j = 0; j < 7; j = j + 1)
                rows[r][111 - 16*j -: 16] = mem_flat[r*7 + j];
    end

    always @(posedge clk) begin
        if (rst) begin
            cnt        <= 3'd0;
            lat_addr   <= 7'd0;
            data_out   <= 112'd0;
            data_valid <= 1'b0;
        end else if (read_en) begin
            lat_addr <= addr;
            if (cnt == 3'd1) begin
                data_out   <= rows[lat_addr];
                data_valid <= 1'b1;
            end else begin
                data_valid <= 1'b0;
            end
            cnt <= LATENCY;
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
