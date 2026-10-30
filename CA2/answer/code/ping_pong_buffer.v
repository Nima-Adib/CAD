// ============================================================================
// Module      : ping_pong_buffer  (Step 3.2 - 3.4 of 05_plan.md)
// Description : Two 7-slot banks of 16-bit entries (one FC row of products).
//               bank_select marks the bank the WRITER is filling; the reader
//               always drains the OTHER bank. swap_req is persistent from the
//               controller; the swap fires exactly when
//               (wr_full && rd_empty) - i.e. the writer barely caught up and
//               the reader completely drained the current read bank.
//               wr_en/rd_en are 1-cycle enables; a beat is dropped silently
//               when the bank is full/empty (the controller guarantees that
//               this never loses valid data: writes are gated by the bank
//               being writable by construction of the drain rate).
//               rd_data is REGISTERED: it shows the entry pointed by rd_ptr
//               in the cycle AFTER the read beat (1-beat-behind read path).
//               rd_empty means "drained" (rd_ptr == 7); after reset the read
//               side starts empty (rd_ptr = 7) so the very first fill fills
//               bank select 0 and the first swap hands it to the reader.
// ============================================================================
`timescale 1ns/1ps

module ping_pong_buffer (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [15:0] wr_data,
    input  wire        rd_en,
    input  wire        swap_req,
    output reg  [15:0] rd_data,
    output wire        wr_full,        // wr_ptr == 7 : writer bank filled
    output wire        rd_empty,       // rd_ptr == 7 : reader bank drained
    output reg         bank_select
);

    reg [15:0] bank0 [0:6];
    reg [15:0] bank1 [0:6];
    reg [2:0]  wr_ptr, rd_ptr;

    assign wr_full  = (wr_ptr == 3'd7);
    assign rd_empty = (rd_ptr == 3'd7);

    wire do_swap = swap_req && wr_full && rd_empty;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr      <= 3'd0;
            rd_ptr      <= 3'd7;          // read side starts empty
            bank_select <= 1'b0;          // first fill goes into bank 0
            rd_data     <= 16'h0000;
        end else if (do_swap) begin
            // Swap with same-cycle transactions preserved (zero-stall):
            // the writer's next product fills slot 0 of the NEW write bank
            // (the just-drained bank) and, if the reader asks, the first
            // entry of the freshly-filled bank is read immediately.
            bank_select <= ~bank_select;
            if (wr_en) begin
                if (bank_select == 1'b0) bank1[3'd0] <= wr_data;   // old read bank
                else                     bank0[3'd0] <= wr_data;
                wr_ptr <= 3'd1;
            end else begin
                wr_ptr <= 3'd0;
            end
            if (rd_en) begin
                if (bank_select == 1'b0) rd_data <= bank0[3'd0];   // old write bank
                else                     rd_data <= bank1[3'd0];
                rd_ptr <= 3'd1;
            end else begin
                rd_ptr <= 3'd0;
            end
        end else begin
            if (wr_en && !wr_full) begin
                if (bank_select == 1'b0) bank0[wr_ptr] <= wr_data;
                else                     bank1[wr_ptr] <= wr_data;
                wr_ptr <= wr_ptr + 3'd1;
            end
            if (rd_en && !rd_empty) begin
                // reader drains the bank opposite to bank_select
                if (bank_select == 1'b0) rd_data <= bank1[rd_ptr];
                else                     rd_data <= bank0[rd_ptr];
                rd_ptr <= rd_ptr + 3'd1;
            end
        end
    end

endmodule
