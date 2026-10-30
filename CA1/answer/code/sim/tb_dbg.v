// Debug tb #10: per-state dwell + full-run harvest
`timescale 1ns/1ps
module tb_dbg;
    reg clk, rst, start;
    wire busy, done;
    wire [159:0] logits_out;
    wire [3:0] pred_digit;

    fcnn_top dut (.clk(clk), .rst(rst), .start(start), .busy(busy),
                  .done(done), .logits_out(logits_out), .pred_digit(pred_digit));

    always #5 clk = ~clk;
    initial begin clk = 0; rst = 1; start = 0; end
    initial begin
        #25 rst = 1'b0; #10;
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
    end

    wire [3:0] st = dut.u_ctrl.state;
    integer dwell [0:15];
    integer total = 0;

    always @(posedge clk) begin
        #2;
        if (!rst) begin
            dwell[st] = dwell[st] + 1;
            total = total + 1;
        end
    end

    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1) dwell[i] = 0;
        wait (done === 1'b1);
        #3;
        $display("TOTAL busy cycles: %0d", total);
        $display("IDLE0 REQ1 WAIT2 RUN3 TAIL4 BIAS5 STORE6 | L2 REQ7 WAIT8 R09 R110 TAIL11 BIAS12 STAGE13 DONE14");
        $display("REQ(phase1)=%0d WAIT=%0d RUN=%0d TAIL=%0d BIAS=%0d STORE=%0d",
                 dwell[1], dwell[2], dwell[3], dwell[4], dwell[5], dwell[6]);
        $display("L2: REQ=%0d WAIT=%0d RUN0=%0d RUN1=%0d TAIL=%0d BIAS=%0d STAGE=%0d DONE=%0d IDLE=%0d",
                 dwell[7], dwell[8], dwell[9], dwell[10], dwell[11], dwell[12], dwell[13],
                 dwell[14], dwell[0]);
        $finish;
    end
    initial begin #250000000 $display("TIMEOUT-TB"); $finish; end
endmodule
