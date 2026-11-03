// ============================================================================
// fp16_adder_model : golden model for tb_fp16_adder.v  (= your fp16_adder_1.v,
// only the module name changed).  NOT part of the synthesized design.
// ============================================================================
`timescale 1ns/1ps

module fp16_adder_model (
    input  wire        clk,
    input  wire        rst,
    input  wire        clr_accum,    // synchronous clear, priority over start
    input  wire        start_add,    // 1-cycle pulse: accum <= accum + operand_b
    input  wire [15:0] operand_b,
    input  wire        add_bias,     // unused (operand mux is in the datapath)
    output wire [15:0] accum_out,
    output reg         add_done      // 1-cycle pulse registered with the sum
);

    reg [15:0] accum_r;
    assign accum_out = accum_r;

    // ---------------- unpack ----------------
    wire [15:0] A = accum_r;
    wire [15:0] B = operand_b;

    wire        sa = A[15], sb = B[15];
    wire [4:0]  ea = A[14:10], eb = B[14:10];
    wire [9:0]  fa = A[9:0],   fb = B[9:0];

    // exponent field == 0 (zero / subnormal) OR mantissa field == 0
    // -> whole operand is treated as zero (CA2 rule)
    // Exception: exp == 31 with mantissa == 0 is the saturated-overflow value
    // and is NOT flushed to zero (it is treated as a normal 2^16 magnitude).
    wire a_zero = (ea == 5'd0) || (fa == 10'd0 && ea != 5'd31);
    wire b_zero = (eb == 5'd0) || (fb == 10'd0 && eb != 5'd31);

    wire [10:0] ma = {1'b1, fa};     // valid only when !a_zero
    wire [10:0] mb = {1'b1, fb};

    // ---------------- order by magnitude ----------------
    wire [5:0] ea6 = {1'b0, ea};
    wire [5:0] eb6 = {1'b0, eb};
    wire a_ge_b = (ea > eb) || ((ea == eb) && (ma >= mb));

    wire        s_big     = a_ge_b ? sa : sb;
    wire [4:0]  e_big     = a_ge_b ? ea : eb;
    wire [10:0] mag_big   = a_ge_b ? ma : mb;
    wire [10:0] mag_small = a_ge_b ? mb : ma;
    wire [5:0]  d         = a_ge_b ? (ea6 - eb6) : (eb6 - ea6);   // 0..29
    wire        same_sign = (sa == sb);

    // ---------------- alignment + add/sub (exact, 44 bit) ----------------
    wire [43:0] big_u    = {mag_big, 33'd0};
    wire [5:0]  small_sh = 6'd33 - d;                  // 4..33
    wire [43:0] small_u  = {33'd0, mag_small} << small_sh;
    wire [44:0] sum_u    = same_sign ? ({1'b0, big_u} + {1'b0, small_u})
                                     : ({1'b0, big_u} - {1'b0, small_u});
    wire        sum_zero = (sum_u == 45'd0);

    // MSB position q of sum_u
    reg [5:0] q;
    integer   i;
    always @* begin
        q = 6'd0;
        for (i = 44; i >= 0; i = i - 1)
            if (sum_u[i] && (q == 6'd0)) q = i[5:0];
    end

    // ---------------- normalize + truncate ----------------
    reg [10:0] sig11;
    always @* begin
        if (q >= 6'd10) sig11 = sum_u >> (q - 6'd10);
        else            sig11 = sum_u << (6'd10 - q);
    end

    // exponent field of result (signed, 8 bit): e_big + q - 43
    wire signed [7:0] e_raw = $signed({3'b0, e_big}) + $signed({2'b0, q}) - 8'sd43;

    wire ovf  = (e_raw >= 8'sd31);
    wire unf  = (e_raw <= 8'sd0);

    // ---------------- result selection ----------------
    reg [15:0] res_comb;
    always @* begin
        if (a_zero && b_zero)      res_comb = 16'h0000;
        else if (a_zero)           res_comb = B;
        else if (b_zero)           res_comb = A;
        else if (sum_zero)         res_comb = 16'h0000;
        else if (ovf)              res_comb = {s_big, 5'd31, 10'h000};
        else if (unf)              res_comb = 16'h0000;
        else                       res_comb = {s_big, e_raw[4:0], sig11[9:0]};
    end

    // ---------------- accumulator register ----------------
    always @(posedge clk) begin
        if (rst) begin
            accum_r  <= 16'h0000;
            add_done <= 1'b0;
        end else begin
            add_done <= start_add;
            if (clr_accum)      accum_r <= 16'h0000;
            else if (start_add) accum_r <= res_comb;
        end
    end

endmodule
