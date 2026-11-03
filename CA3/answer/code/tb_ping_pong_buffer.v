// ============================================================================
// Testbench : tb_ping_pong_buffer   (CA2 - Ping-Pong Buffer)
// Sections:
//   1. Reset & empty read rejection
//   2. Bank 0 write & fill (7 beats, wr_full flag)
//   3. Swap handshake (bank_select toggles, reader side ready)
//   4. Bank 0 drain in FIFO order & empty flag
//   5. Concurrent swap + write & zero-stall read
//   6. Full double-buffer alternation round-trip
// ============================================================================
`timescale 1ns/1ps

module tb_ping_pong_buffer;

    reg         clk = 1'b0, rst;
    reg         wr_en, rd_en, swap_req;
    reg  [15:0] wr_data;
    wire [15:0] rd_data;
    wire        wr_full, rd_empty, bank_select;

    always #5 clk = ~clk;

    ping_pong_buffer dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_data(wr_data),
        .rd_en(rd_en), .swap_req(swap_req),
        .rd_data(rd_data),
        .wr_full(wr_full), .rd_empty(rd_empty),
        .bank_select(bank_select)
    );

    initial begin
        $dumpfile("final.vcd");
        $dumpvars(0, tb_ping_pong_buffer);
    end

    integer errors, total;

    // -------- helpers --------
    task check(input [15:0] got_d, input [15:0] exp_d,
               input got_f, input exp_f,
               input got_e, input exp_e,
               input got_bs, input exp_bs,
               input [255:0] name);
        begin
            total = total + 1;
            if (got_d !== exp_d || got_f !== exp_f || got_e !== exp_e || got_bs !== exp_bs) begin
                errors = errors + 1;
                if (errors <= 40)
                    $display("MISMATCH [%0s] rd=%h (exp %h) f=%b (exp %b) e=%b (exp %b) bs=%b (exp %b)",
                             name, got_d, exp_d, got_f, exp_f, got_e, exp_e, got_bs, exp_bs);
            end
        end
    endtask

    // advance one clock edge with stimulus
    task step(input w, input r, input s, input [15:0] d,
              input [15:0] exp_d, input exp_f, input exp_e, input exp_bs,
              input [255:0] name);
        begin
            @(negedge clk);
            wr_en <= w; rd_en <= r; swap_req <= s; wr_data <= d;
            @(posedge clk); #1;
            check(rd_data, exp_d, wr_full, exp_f, rd_empty, exp_e, bank_select, exp_bs, name);
        end
    endtask

    integer i;

    initial begin
        errors = 0; total = 0;
        rst = 1'b1; wr_en = 1'b0; rd_en = 1'b0; swap_req = 1'b0; wr_data = 16'h0000;
        #22 rst = 1'b0;

        // ===================== 1. reset & empty reads =====================
        $display("--- reset & empty read tests ---");
        // Initial reset state: wr_ptr=0 (not full), rd_ptr=7 (empty), bs=0
        step(0, 0, 0, 16'h0000, 16'h0000, 0, 1, 0, "reset state");
        // Read while empty: dropped silently, rd_data holds 0
        step(0, 1, 0, 16'h0000, 16'h0000, 0, 1, 0, "read while empty 1");
        step(0, 1, 0, 16'h0000, 16'h0000, 0, 1, 0, "read while empty 2");

        // ===================== 2. fill bank0 =====================
        $display("--- fill bank0 (7 beats) ---");
        for (i = 0; i < 7; i = i + 1) begin
            step(1, 0, 0, 16'h1000 + i, 16'h0000, (i == 6), 1, 0, "fill bank0");
        end
        // Attempt write when full: dropped silently, remains full
        step(1, 0, 0, 16'hDEAD, 16'h0000, 1, 1, 0, "write while full ignored");

        // ===================== 3. swap handshake =====================
        $display("--- swap handshake ---");
        // swap_req fires because wr_full=1 and rd_empty=1
        // reader gains bank0 (rd_empty drops to 0), writer gets bank1, bank_select toggles to 1
        step(0, 0, 1, 16'h0000, 16'h0000, 0, 0, 1, "swap fires");

        // ===================== 4. zero-stall concurrent read/write =====================
        $display("--- zero-stall concurrent read/write ---");
        // Same-cycle: write 0xF00D into slot0 of bank1, read bank0 slot0 -> rd_data shows 1000 1 cycle later
        step(1, 1, 0, 16'hF00D, 16'h1000, 0, 0, 1, "zero-stall read+write");

        // ===================== 5. drain bank0 in FIFO order =====================
        $display("--- drain bank0 in FIFO order ---");
        for (i = 2; i <= 7; i = i + 1) begin
            step(0, 1, 0, 16'h0000, 16'h1000 + i - 1, 0, (i == 7), 1, "drain bank0");
        end
        // Read while empty after drain: dropped, rd_data holds last word
        step(0, 1, 0, 16'h0000, 16'h1006, 0, 1, 1, "read while empty after drain");

        // ===================== 6. refill bank1 & swap with write-through =====================
        $display("--- refill bank1 & swap with write-through ---");
        // Bank1 slot 0 already has 0xF00D, write remaining 6 beats
        for (i = 1; i <= 6; i = i + 1) begin
            step(1, 0, 0, 16'h2000 + i, 16'h1006, (i == 6), 1, 1, "refill bank1");
        end
        // Swap with concurrent write: 0x9999 lands in slot 0 of NEW write bank (bank0)
        step(1, 0, 1, 16'h9999, 16'h1006, 0, 0, 0, "swap with concurrent write");

        // Drain bank1 (verify FIFO order: F00D, 2001..2006)
        step(0, 1, 0, 16'h0000, 16'hF00D, 0, 0, 0, "drain bank1 word 0");
        for (i = 1; i <= 6; i = i + 1) begin
            step(0, 1, 0, 16'h0000, 16'h2000 + i, 0, (i == 6), 0, "drain bank1 words");
        end

        // Refill bank0 (slot 0 has 0x9999, fill remaining 6 beats)
        for (i = 1; i <= 6; i = i + 1) begin
            step(1, 0, 0, 16'h3000 + i, 16'h2006, (i == 6), 1, 0, "refill bank0");
        end
        // Swap back to bank0
        step(0, 0, 1, 16'h0000, 16'h2006, 0, 0, 1, "swap back");

        // Verify the swap-cycle write landed: first word read is 0x9999
        step(0, 1, 0, 16'h0000, 16'h9999, 0, 0, 1, "verify swap-cycle word");
        for (i = 1; i <= 6; i = i + 1) begin
            step(0, 1, 0, 16'h0000, 16'h3000 + i, 0, (i == 6), 1, "drain remaining");
        end

        $display("PPB-TB: checks=%0d errors=%0d", total, errors);
        if (errors == 0) $display("PPB-TB PASS");
        else             $display("PPB-TB FAIL");
        $finish;
    end

    initial begin #500000000 $display("TIMEOUT"); $finish; end

endmodule
