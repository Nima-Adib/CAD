// ============================================================================
// actel_gates.v
// Basic building blocks made ONLY from the Actel logic cell c1.
// Every module below contains exactly ONE c1 instance (10 gates in gated.txt).
//
//   c1 :  f = (S0 | S1) ? (SB ? B1 : B0) : (SA ? A1 : A0)
//
// No logic operator (& | ^ ~ ?:) is used anywhere in the design - only cells.
// ============================================================================
`timescale 1ns/1ps

// y = s ? a1 : a0
module g_mux2 (input a0, a1, s, output y);
    c1 u (.A0(a0), .A1(a1), .SA(s), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(1'b0), .S1(1'b0), .f(y));
endmodule

// y = a & b
module g_and (input a, b, output y);
    c1 u (.A0(1'b0), .A1(b), .SA(a), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(1'b0), .S1(1'b0), .f(y));
endmodule

// y = ~a & b
module g_andn (input a, b, output y);
    c1 u (.A0(1'b0), .A1(1'b1), .SA(b), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(a), .S1(1'b0), .f(y));
endmodule

// y = a | b
module g_or (input a, b, output y);
    c1 u (.A0(b), .A1(1'b1), .SA(a), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(1'b0), .S1(1'b0), .f(y));
endmodule

// y = ~a
module g_not (input a, output y);
    c1 u (.A0(1'b1), .A1(1'b0), .SA(a), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(1'b0), .S1(1'b0), .f(y));
endmodule

// y = ~(a | b)      (the OR comes for free from  S0 | S1)
module g_nor (input a, b, output y);
    c1 u (.A0(1'b1), .A1(1'b0), .SA(1'b0), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(a), .S1(b), .f(y));
endmodule

// y = a ^ b
module g_xor (input a, b, output y);
    c1 u (.A0(1'b0), .A1(1'b1), .SA(b), .B0(1'b1), .B1(1'b0), .SB(b),
          .S0(a), .S1(1'b0), .f(y));
endmodule

// y = ~(a ^ b)
module g_xnor (input a, b, output y);
    c1 u (.A0(1'b1), .A1(1'b0), .SA(b), .B0(1'b0), .B1(1'b1), .SB(b),
          .S0(a), .S1(1'b0), .f(y));
endmodule

// y = a ^ b ^ s   (s and its complement ns are supplied by the caller)
module g_xor3 (input a, b, s, ns, output y);
    c1 u (.A0(s), .A1(ns), .SA(b), .B0(ns), .B1(s), .SB(b),
          .S0(a), .S1(1'b0), .f(y));
endmodule

// 4:1 mux : y = d[{s1,s0}]
module g_mux4 (input d0, d1, d2, d3, s1, s0, output y);
    c1 u (.A0(d0), .A1(d1), .SA(s0), .B0(d2), .B1(d3), .SB(s0),
          .S0(s1), .S1(1'b0), .f(y));
endmodule

// y = a | b | c | d
module g_or4 (input a, b, c, d, output y);
    c1 u (.A0(d), .A1(1'b1), .SA(c), .B0(1'b1), .B1(1'b1), .SB(1'b0),
          .S0(a), .S1(b), .f(y));
endmodule

// y = a & b & c
module g_and3 (input a, b, c, output y);
    c1 u (.A0(1'b0), .A1(1'b0), .SA(1'b0), .B0(1'b0), .B1(c), .SB(b),
          .S0(a), .S1(1'b0), .f(y));
endmodule

// y = ~(a | b | c) & d
module g_nor3_and (input a, b, c, d, output y);
    c1 u (.A0(d), .A1(1'b0), .SA(c), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(a), .S1(b), .f(y));
endmodule

// magnitude-compare slice:  y = (a > b) | ((a == b) & gp)
module g_cmp (input a, b, gp, output y);
    c1 u (.A0(gp), .A1(1'b0), .SA(b), .B0(1'b1), .B1(gp), .SB(b),
          .S0(a), .S1(1'b0), .f(y));
endmodule

// masked 2:1 mux :  y = s ? (m1 ? d1 : 0) : (m0 ? d0 : 0)
module g_mmux2 (input d0, m0, d1, m1, s, output y);
    c1 u (.A0(1'b0), .A1(d0), .SA(m0), .B0(1'b0), .B1(d1), .SB(m1),
          .S0(s), .S1(1'b0), .f(y));
endmodule

// leading-zero helper :  y = ~x2 & (x1 | ~x0)
module g_lz (input x2, x1, x0, output y);
    c1 u (.A0(1'b1), .A1(x1), .SA(x0), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(x2), .S1(1'b0), .f(y));
endmodule

// y = ~a & b & c
module g_andn2 (input a, b, c, output y);
    c1 u (.A0(1'b0), .A1(c), .SA(b), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(a), .S1(1'b0), .f(y));
endmodule

// exponent underflow flag :  y = q4 & (~c5 | zs)
module g_under (input q4, c5, zs, output y);
    c1 u (.A0(1'b0), .A1(1'b0), .SA(1'b0), .B0(1'b1), .B1(zs), .SB(c5),
          .S0(q4), .S1(1'b0), .f(y));
endmodule

// exponent overflow flag :  y = ~q4 & (c5 | os)
module g_ovf (input q4, c5, os, output y);
    c1 u (.A0(os), .A1(1'b1), .SA(c5), .B0(1'b0), .B1(1'b0), .SB(1'b0),
          .S0(q4), .S1(1'b0), .f(y));
endmodule
