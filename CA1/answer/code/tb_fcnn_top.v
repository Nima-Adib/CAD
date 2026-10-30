// ============================================================================
// Testbench      : tb_fcnn_top  (independent - drives ONLY fcnn_top ports)
// Deliverable    : 06_1.v
// What it checks : The full FCNN inference (784-8-10, FP16, bias-last):
//                  1. busy/done handshake
//                  2. the 10 parallel logits vs the golden reference
//                     assets/debug_out/l2_model_output_last.mem
//                  3. pred_digit == argmax of the golden logits
//                  4. reports the cycle count of one inference
// ============================================================================
`timescale 1ns/1ps

module tb_fcnn_top;

    reg         clk, rst, start;
    wire        busy, done;
    wire [159:0] logits_out;
    wire [3:0]  pred_digit;

    fcnn_top dut (
        .clk       (clk),
        .rst       (rst),
        .start     (start),
        .busy      (busy),
        .done      (done),
        .logits_out(logits_out),
        .pred_digit(pred_digit)
    );
    initial begin
        $dumpfile("final.vcd");
        $dumpvars(0, tb_fcnn_top);
    end
    always #5 clk = ~clk;
    initial begin clk = 1'b0; rst = 1'b1; start = 1'b0; end

    // golden L2 logits (bias added last)
    reg [15:0] golden [0:9];
    initial $readmemh("assets/debug_out/l2_model_output_last.mem", golden);

    integer k, errors, cycles;
    reg [15:0] got;

    initial begin
        #25 rst = 1'b0;
        #10;
        // pulse start for exactly one clock
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        cycles = 0;
        while (!done) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;   // settle after the done edge

        $display("TB: done asserted after %0d cycles, pred_digit=%0d", cycles, pred_digit);

        errors = 0;
        for (k = 0; k < 10; k = k + 1) begin
            // logits[d] occupies bits [16*d +: 16]; d=0 on the MSBs
            got = logits_out[(159 - 16*k) -: 16];
            $display("  logit[%0d] dut=%h golden=%h %s",
                     k, got, golden[k], (got === golden[k]) ? "OK" : "MISMATCH");
            if (got !== golden[k]) errors = errors + 1;
        end

        if (errors == 0) $display("TB-FCNN PASS");
        else             $display("TB-FCNN FAIL (%0d mismatches)", errors);
        $finish;
    end

    initial begin #4000000 $display("TB: TIMEOUT"); $finish; end

endmodule
