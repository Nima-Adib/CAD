`timescale 1ns/1ps

module fp16_multiplier_model (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] result,
    output reg         valid_out
);

    // ---------------- unpack ----------------
    wire        s_a   = a[15];
    wire        s_b   = b[15];
    wire [4:0]  e_a   = a[14:10];
    wire [4:0]  e_b   = b[14:10];
    wire [9:0]  f_a   = a[9:0];
    wire [9:0]  f_b   = b[9:0];
    wire        s_res = s_a ^ s_b;

    // zero (and subnormal) detection: ONLY the exponent matters
    wire a_zero = (e_a == 5'd0);
    wire b_zero = (e_b == 5'd0);

    // significands with hidden bit (valid whenever the operand is non-zero)
    wire [10:0] m_a = {1'b1, f_a};
    wire [10:0] m_b = {1'b1, f_b};

    // ---------------- mantissa product ----------------
    wire [21:0] p = m_a * m_b;

    // ---------------- normalize ----------------
    // p is in [2^20, 2^22) so the MSB is either bit 21 or bit 20.
    wire        carry = p[21];
    wire [9:0]  frac  = carry ? p[20:11] : p[19:10];   // truncated

    // biased result exponent: e_a + e_b - 15 + carry   (range -13 .. 48)
    wire signed [7:0] e_raw = $signed({3'b0, e_a}) + $signed({3'b0, e_b})
                            - 8'sd15 + $signed({7'b0, carry});

    wire ovf  = (e_raw >= 8'sd31);
    wire unf  = (e_raw <= 8'sd0);

    // ---------------- final packing ----------------
    reg [15:0] res_comb;
    always @* begin
        if (a_zero || b_zero)
            res_comb = {s_res, 15'h0000};               // zero input
        else if (ovf)
            res_comb = {s_res, 5'h1F, 10'h000};         // exp = 31, mant = 0
        else if (unf)
            res_comb = {s_res, 15'h0000};               // underflow -> zero
        else
            res_comb = {s_res, e_raw[4:0], frac};       // normal
    end

    // ---------------- registered output ----------------
    always @(posedge clk) begin
        if (rst) begin
            result    <= 16'h0000;
            valid_out <= 1'b0;
        end else begin
            result    <= res_comb;
            valid_out <= valid_in;
        end
    end

endmodule