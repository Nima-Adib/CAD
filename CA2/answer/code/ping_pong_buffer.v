// // ============================================================================
// // Module      : ping_pong_buffer  (Step 3.2 - 3.4 of 05_plan.md)
// // Description : Two 7-slot banks of 16-bit entries (one FC row of products).
// //               bank_select marks the bank the WRITER is filling; the reader
// //               always drains the OTHER bank. swap_req is persistent from the
// //               controller; the swap fires exactly when
// //               (wr_full && rd_empty) - i.e. the writer barely caught up and
// //               the reader completely drained the current read bank.
// //               wr_en/rd_en are 1-cycle enables; a beat is dropped silently
// //               when the bank is full/empty (the controller guarantees that
// //               this never loses valid data: writes are gated by the bank
// //               being writable by construction of the drain rate).
// //               rd_data is REGISTERED: it shows the entry pointed by rd_ptr
// //               in the cycle AFTER the read beat (1-beat-behind read path).
// //               rd_empty means "drained" (rd_ptr == 7); after reset the read
// //               side starts empty (rd_ptr = 7) so the very first fill fills
// //               bank select 0 and the first swap hands it to the reader.
// // ============================================================================
// `timescale 1ns/1ps

// module ping_pong_buffer (
//     input  wire        clk,
//     input  wire        rst,
//     input  wire        wr_en,
//     input  wire [15:0] wr_data,
//     input  wire        rd_en,
//     input  wire        swap_req,
//     output reg  [15:0] rd_data,
//     output wire        wr_full,        // wr_ptr == 7 : writer bank filled
//     output wire        rd_empty,       // rd_ptr == 7 : reader bank drained
//     output reg         bank_select
// );

//     reg [15:0] bank0 [0:6];
//     reg [15:0] bank1 [0:6];
//     reg [2:0]  wr_ptr, rd_ptr;

//     assign wr_full  = (wr_ptr == 3'd7);
//     assign rd_empty = (rd_ptr == 3'd7);

//     wire do_swap = swap_req && wr_full && rd_empty;

//     always @(posedge clk) begin
//         if (rst) begin
//             wr_ptr      <= 3'd0;
//             rd_ptr      <= 3'd7;          // read side starts empty
//             bank_select <= 1'b0;          // first fill goes into bank 0
//             rd_data     <= 16'h0000;
//         end else if (do_swap) begin
//             // Swap with same-cycle transactions preserved (zero-stall):
//             // the writer's next product fills slot 0 of the NEW write bank
//             // (the just-drained bank) and, if the reader asks, the first
//             // entry of the freshly-filled bank is read immediately.
//             bank_select <= ~bank_select;
//             if (wr_en) begin
//                 if (bank_select == 1'b0) bank1[3'd0] <= wr_data;   // old read bank
//                 else                     bank0[3'd0] <= wr_data;
//                 wr_ptr <= 3'd1;
//             end else begin
//                 wr_ptr <= 3'd0;
//             end
//             if (rd_en) begin
//                 if (bank_select == 1'b0) rd_data <= bank0[3'd0];   // old write bank
//                 else                     rd_data <= bank1[3'd0];
//                 rd_ptr <= 3'd1;
//             end else begin
//                 rd_ptr <= 3'd0;
//             end
//         end else begin
//             if (wr_en && !wr_full) begin
//                 if (bank_select == 1'b0) bank0[wr_ptr] <= wr_data;
//                 else                     bank1[wr_ptr] <= wr_data;
//                 wr_ptr <= wr_ptr + 3'd1;
//             end
//             if (rd_en && !rd_empty) begin
//                 // reader drains the bank opposite to bank_select
//                 if (bank_select == 1'b0) rd_data <= bank1[rd_ptr];
//                 else                     rd_data <= bank0[rd_ptr];
//                 rd_ptr <= rd_ptr + 3'd1;
//             end
//         end
//     end

// endmodule


// ============================================================================
// ping_pong_buffer -- hierarchical, PURE-STRUCTURAL cell netlist  (v3, gate-optimized)
// Leaf cells: c1 / c2 / s1 / s2 ONLY.  No assign, no always, no operators.
// Gate cost: c1=10, c2=11, s1=13, s2=13.
// Cells: 224 s1 + 23 s2 + 11 c1 = 258  ->  3321 gates
//   (v1: 258 cells / 3336 gates;  flop floor = 247 flops = 3211 gates)
//
//   ping_pong_buffer
//    |- ppb_flags    5 c1   F, E, ds, tw, tr
//    |- ppb_sel      4 c1   nrst, a1, sh0, sh1
//    |- ppb_cw       3 s2 + 1 c1   write pointer (3-flop shift counter)
//    |- ppb_cr       3 s2 + 1 c1   read  pointer
//    |- ppb_bs       1 s2   bank_select flop
//    |- ppb_bank x2  112 s1 each  (7 slots x 16 bit shift register)
//    '- ppb_rdreg    16 s2  rd_data register
// X-robust reset rule: on rst the selects are forced so the reset value is chosen
// independent of unknown state.  Tie-offs 1'b0/1'b1 on cell pins are assumed free.
// ============================================================================

// ---------------- 5 c1 : status / beat flags ----------------
// c1: f = (S0|S1) ? (SB?B1:B0) : (SA?A1:A0)      (10 gates, cheaper than c2 = 11)
module ppb_flags (
    input  wire wa, wb, wc, ra, rb, rc, swap_req, wr_en, rd_en,
    output wire wr_full, rd_empty, ds, tw, tr
);
    // wr_full = state7 = 100 = a & ~b & ~c  ->  (b|c) ? 0 : a
    c1 u_F  (.S0(wb),.S1(wc),.SB(1'b0),.B0(1'b0),.B1(1'b0),.SA(1'b0),.A0(wa),.A1(wa),.f(wr_full));
    // rd_empty (same encoding)
    c1 u_E  (.S0(rb),.S1(rc),.SB(1'b0),.B0(1'b0),.B1(1'b0),.SA(1'b0),.A0(ra),.A1(ra),.f(rd_empty));
    // ds = swap_req & wr_full & rd_empty  ->  F ? (E ? swap_req : 0) : 0
    c1 u_ds (.S0(wr_full),.S1(1'b0),.SB(rd_empty),.B0(1'b0),.B1(swap_req),.SA(1'b0),.A0(1'b0),.A1(1'b0),.f(ds));
    // tw = wr_en & (~wr_full | ds)        ->  F ? (ds ? wr_en : 0) : wr_en
    c1 u_tw (.S0(wr_full),.S1(1'b0),.SB(ds),.B0(1'b0),.B1(wr_en),.SA(1'b0),.A0(wr_en),.A1(wr_en),.f(tw));
    // tr = rd_en & (~rd_empty | ds)       ->  E ? (ds ? rd_en : 0) : rd_en
    c1 u_tr (.S0(rd_empty),.S1(1'b0),.SB(ds),.B0(1'b0),.B1(rd_en),.SA(1'b0),.A0(rd_en),.A1(rd_en),.f(tr));
endmodule

// ---------------- 4 c1 : reset inverse, read-bank select, bank shift enables ----------------
module ppb_sel (
    input  wire rst, bs, ds, tw, tr,
    output wire nrst, a1, sh0, sh1
);
    // nrst = ~rst
    c1 u_nr (.S0(rst),.S1(1'b0),.SB(1'b0),.B0(1'b0),.B1(1'b0),.SA(1'b0),.A0(1'b1),.A1(1'b1),.f(nrst));
    // a1 = tr & (bs == ds)   (read bank is bank 1)
    c1 u_a1 (.S0(bs),.S1(1'b0),.SB(ds),.B0(1'b0),.B1(tr),.SA(ds),.A0(tr),.A1(1'b0),.f(a1));
    // write bank = bs ^ ds shifts on tw, read bank shifts on tr
    c1 u_sh0(.S0(bs),.S1(1'b0),.SB(ds),.B0(tr),.B1(tw),.SA(ds),.A0(tw),.A1(tr),.f(sh0));
    c1 u_sh1(.S0(bs),.S1(1'b0),.SB(ds),.B0(tw),.B1(tr),.SA(ds),.A0(tr),.A1(tw),.f(sh1));
endmodule

// ---------------- 3 s2 + 1 c1 : write pointer, 3-flop shift counter, reset = state 0 = 000 ----------------
// State codes (a,b,c), n = 0..7:  000 001 010 101 011 111 110 100   (7 = 100 = full)
// Advance is a plain shift: a<=b, b<=c, c<=f with f = a ? ~b : (c ? b : 1)  (ONE c1 helper).
// 7 -> 1 (swap with beat) is f(100)=1; 7 -> 0 (swap, no beat) is the clear.
// FULLY X-ROBUST reset: every flop has s1 = rst|.. and s0 = ..&nrst, so on rst the code is
// forced to (1,0) whatever the (possibly unknown) state/inputs are; reset value sits on D10.
// (Exhaustive search over all 8! encodings: no 3-flop counter with ZERO helpers is X-robust.)
module ppb_cw (
    input  wire clk, rst, nrst, tw, ds,
    output wire [2:0] w            // w[2]=a, w[1]=b, w[0]=c
);
    wire f;
    c1 u_f (.S0(1'b0),.S1(w[2]),.SB(w[1]),.B0(1'b1),.B1(1'b0),.SA(w[0]),.A0(1'b1),.A1(w[1]),.f(f));
    // a: s1 = rst|ds, s0 = tw&nrst : 00 hold, 01 shift b, 10 -> 0 (reset or clear), 11 -> 0 (7->1 keeps a=0)
    s2 u_a (.D00(w[2]),.D01(w[1]),.D10(1'b0),.D11(1'b0),.A1(rst),.B1(ds),.A0(tw),.B0(nrst),.clr(1'b0),.clk(clk),.out(w[2]));
    s2 u_b (.D00(w[1]),.D01(w[0]),.D10(1'b0),.D11(1'b0),.A1(rst),.B1(1'b0),.A0(tw),.B0(nrst),.clr(1'b0),.clk(clk),.out(w[1]));
    s2 u_c (.D00(w[0]),.D01(f),.D10(1'b0),.D11(1'b0),.A1(rst),.B1(1'b0),.A0(tw),.B0(nrst),.clr(1'b0),.clk(clk),.out(w[0]));
endmodule

// ---------------- 3 s2 + 1 c1 : read pointer, same counter, reset = state 7 = 100 ----------------
module ppb_cr (
    input  wire clk, rst, nrst, tr, ds,
    output wire [2:0] r
);
    wire f;
    c1 u_f (.S0(1'b0),.S1(r[2]),.SB(r[1]),.B0(1'b1),.B1(1'b0),.SA(r[0]),.A0(1'b1),.A1(r[1]),.f(f));
    // a: reset value 1, ds clears to 0 : D10 = rst separates the two (1 at rst, 0 at ds)
    s2 u_a (.D00(r[2]),.D01(r[1]),.D10(rst),.D11(1'b0),.A1(rst),.B1(ds),.A0(tr),.B0(nrst),.clr(1'b0),.clk(clk),.out(r[2]));
    s2 u_b (.D00(r[1]),.D01(r[0]),.D10(1'b0),.D11(1'b0),.A1(rst),.B1(1'b0),.A0(tr),.B0(nrst),.clr(1'b0),.clk(clk),.out(r[1]));
    s2 u_c (.D00(r[0]),.D01(f),.D10(1'b0),.D11(1'b0),.A1(rst),.B1(1'b0),.A0(tr),.B0(nrst),.clr(1'b0),.clk(clk),.out(r[0]));
endmodule

// ---------------- 1 s2 : bank_select (reset 0, toggles on ds) ----------------
module ppb_bs (
    input  wire clk, rst, nrst, ds,
    output wire bs
);
    s2 u_bs (.D00(1'b0),.D01(1'b1),.D10(nrst),.D11(1'b0),.A1(bs),.B1(rst),.A0(ds),.B0(nrst),.clr(1'b0),.clk(clk),.out(bs));
endmodule

// ---------------- 112 s1 : one bank = 7 slots x 16 bit shift register ----------------
// slot i <= sh ? slot[i+1] : slot[i];  slot 6 <= sh ? wr_data : slot[6].  q index = slot*16+bit.
module ppb_bank (
    input  wire clk, sh,
    input  wire [15:0] wr_data,
    output wire [111:0] q
);
    genvar i, b;
    generate
        for (i = 0; i < 7; i = i + 1) begin : g_slot
            for (b = 0; b < 16; b = b + 1) begin : g_bit
                if (i == 6) begin : g_in
                    s1 u (.D00(q[i*16+b]),.D01(1'b0),.D10(wr_data[b]),.D11(1'b0),.A1(sh),.B1(1'b0),.A0(1'b0),.clr(1'b0),.clk(clk),.out(q[i*16+b]));
                end else begin : g_sh
                    s1 u (.D00(q[i*16+b]),.D01(1'b0),.D10(q[(i+1)*16+b]),.D11(1'b0),.A1(sh),.B1(1'b0),.A0(1'b0),.clr(1'b0),.clk(clk),.out(q[i*16+b]));
                end
            end
        end
    endgenerate
endmodule

// ---------------- 16 s2 : rd_data register {hold, head0, head1, 0} ----------------
module ppb_rdreg (
    input  wire clk, rst, nrst, a1, tr,
    input  wire [15:0] head0, head1,
    output wire [15:0] rd_data
);
    genvar b;
    generate
        for (b = 0; b < 16; b = b + 1) begin : g_rd
            // s1 = a1|rst, s0 = tr&nrst : 00 hold, 01 head0, 11 head1, 10 zero
            s2 u (.D00(rd_data[b]),.D01(head0[b]),.D10(1'b0),.D11(head1[b]),
                  .A1(a1),.B1(rst),.A0(tr),.B0(nrst),.clr(1'b0),.clk(clk),.out(rd_data[b]));
        end
    endgenerate
endmodule

// ---------------- top ----------------
module ping_pong_buffer (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [15:0] wr_data,
    input  wire        rd_en,
    input  wire        swap_req,
    output wire [15:0] rd_data,
    output wire        wr_full,
    output wire        rd_empty,
    output wire        bank_select
);
    wire [2:0]   w, r;
    wire         ds, tw, tr, nrst, a1, sh0, sh1;
    wire [111:0] q0, q1;

    ppb_flags u_flags (.wa(w[2]),.wb(w[1]),.wc(w[0]),.ra(r[2]),.rb(r[1]),.rc(r[0]),.swap_req(swap_req),.wr_en(wr_en),.rd_en(rd_en),
                       .wr_full(wr_full),.rd_empty(rd_empty),.ds(ds),.tw(tw),.tr(tr));
    ppb_sel   u_sel   (.rst(rst),.bs(bank_select),.ds(ds),.tw(tw),.tr(tr),.nrst(nrst),.a1(a1),.sh0(sh0),.sh1(sh1));
    ppb_cw    u_cw    (.clk(clk),.rst(rst),.nrst(nrst),.tw(tw),.ds(ds),.w(w));
    ppb_cr    u_cr    (.clk(clk),.rst(rst),.nrst(nrst),.tr(tr),.ds(ds),.r(r));
    ppb_bs    u_bs    (.clk(clk),.rst(rst),.nrst(nrst),.ds(ds),.bs(bank_select));
    ppb_bank  u_bank0 (.clk(clk),.sh(sh0),.wr_data(wr_data),.q(q0));
    ppb_bank  u_bank1 (.clk(clk),.sh(sh1),.wr_data(wr_data),.q(q1));
    ppb_rdreg u_rd    (.clk(clk),.rst(rst),.nrst(nrst),.a1(a1),.tr(tr),.head0(q0[15:0]),.head1(q1[15:0]),.rd_data(rd_data));
endmodule
