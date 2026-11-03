`timescale 1ns / 1ps

module tb_Top();

    reg clk;
    reg rst;
    reg start;
    wire done;

    integer i;

    fcnn_top uut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .done(done)
    );

    always #5 clk = ~clk;

    function real fp16_to_real;
        input [15:0] fp16;

        reg sign;
        reg [4:0] exponent;
        reg [9:0] fraction;

        real mantissa;
        integer exp_value;

        begin
            sign     = fp16[15];
            exponent = fp16[14:10];
            fraction = fp16[9:0];

            if (exponent == 0) begin
                fp16_to_real = 0.0;
            end
            else if (exponent == 31) begin
                if (fraction == 0) begin
                    if (sign)
                        fp16_to_real = -1.0e300;
                    else
                        fp16_to_real = 1.0e300;
                end
                else begin
                    fp16_to_real = 0.0;
                end
            end
            else begin
                mantissa = 1.0 + fraction / 1024.0;
                exp_value = exponent - 15;

                fp16_to_real = mantissa * (2.0 ** exp_value);

                if (sign)
                    fp16_to_real = -fp16_to_real;
            end
        end
    endfunction

    initial begin
        clk   = 0;
        rst   = 1;
        start = 0;

        #20;
        rst = 0;

        #10;
        start = 1;

        #10;
        start = 0;

        $display("Neural Network started. Waiting for completion...");

        wait(done == 1'b1);
        #50;

        $display("");
        $display("Inference Completed Successfully!");
        $display("================================================");
        $display("          Final FCNN Output Values");
        $display("================================================");
        $display("Index | FP16 Hex | Decimal");
        $display("------------------------------------------------");

        for (i = 0; i < 10; i = i + 1) begin
            $display(
                "%5d | %8h | %f",
                i,
                uut.u_dp.u_rf.rf[i+8], // FP16 value of output neuron i (logits live in rf[8..17])
                fp16_to_real(uut.u_dp.u_rf.rf[i+8])
            );
        end

        $display("================================================");

        $finish;
    end

endmodule