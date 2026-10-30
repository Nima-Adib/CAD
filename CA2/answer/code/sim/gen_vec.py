#!/usr/bin/env python3
# Generate random + patterned FP16 test vectors for the RTL unit tests.
# Outputs (hex, one 16-bit word per token):
#   vec_mult_ab.mem  : pairs (a, b)        2 words/line
#   vec_mult_exp.mem : expected a*b        1 word/line  (numpy fp16 semantics)
#   vec_add_ab.mem   : pairs (acc, addend) 2 words/line
#   vec_add_exp.mem  : expected acc+op     1 word/line  (numpy fp16 semantics)
import numpy as np, random, os

random.seed(20261)
np.random.seed(20261)
OUT = os.path.dirname(os.path.abspath(__file__))

N_RAND   = 20000   # fully random finite operands (mixed exponent classes)
N_TIE    = 4000    # structured rounding-boundary probes
N_EXP    = 2000    # exponent sweep around the subnormal boundary

EXP_POOL = [0,0,1,1,2,3,5,7,10,14,15,15,16,18,20,24,28,30]   # finite only (no 31)

def rand_fp16():
    e = random.choice(EXP_POOL)
    f = random.getrandbits(10)
    s = random.getrandbits(1)
    return (s << 15) | (e << 10) | f

def bias_normal(e, f, s=0):
    return (s << 15) | ((e + 15) << 10) | f

ab_m, exp_m = [], []
ab_a, exp_a = [], []

def push_pair(op, x, y):
    assert not ((x & 0x7C00) == 0x7C00 and (x & 0x3FF) != 0), "NaN operand x"
    assert not ((y & 0x7C00) == 0x7C00 and (y & 0x3FF) != 0), "NaN operand y"
    ab = ab_m if op == 'm' else ab_a
    ex = exp_m if op == 'm' else exp_a
    xa = np.frombuffer(np.uint16(x).tobytes(), dtype=np.uint16).view(np.float16)
    xb = np.frombuffer(np.uint16(y).tobytes(), dtype=np.uint16).view(np.float16)
    if op == 'm':
        r = np.float16(np.float16(xa.reshape(1)[0]) * xb.reshape(1)[0])
    else:
        # exactly what fcnn_debug.py accumulates: np.float16(acc + prod)
        r = np.float16(np.float16(xa.reshape(1)[0]) + xb.reshape(1)[0])
    ab.append((x, y))
    # extract raw IEEE-754 bits (never cast via integer arithmetic!)
    ex.append(int(np.frombuffer(r.tobytes(), dtype=np.uint16)[0]))

# 1) random finite
for _ in range(N_RAND // 2):
    push_pair('m', rand_fp16(), rand_fp16())
    push_pair('a', rand_fp16(), rand_fp16())

# 2) structured rounding-boundary probes (mantissa patterns near ties)
MATS = [0x000,0x001,0x002,0x155,0x155,0x200,0x201,0x3FD,0x3FE,0x3FF,0x400,0x401,0x402,
        0x555,0x7FF,0x7FE,0x2AA,0x2AB]
# use as 10-bit fractions: keep low 10 bits only (0x400+ are hidden-bit mantissas)
FRACS = [m & 0x3FF for m in MATS]
for a in FRACS:
    for b in FRACS:
        if random.random() < 0.45:
            push_pair('m', bias_normal(random.choice([0,1,7,15]), a, random.getrandbits(1)),
                          bias_normal(random.choice([0,1,7,15]), b, random.getrandbits(1)))
            push_pair('a', bias_normal(random.choice([1,7,10,15]), a, random.getrandbits(1)),
                          bias_normal(random.choice([1,7,10,15]), b, random.getrandbits(1)))
# subnormal operands / results sweep
for a in FRACS[:8]:
    for b in FRACS[:8]:
        push_pair('m', (random.getrandbits(1) << 15) | a,           # subnormal a (e=0)
                      bias_normal(random.choice([0,1,2,14]), b, random.getrandbits(1)))
        push_pair('m', bias_normal(random.choice([0,1,2]), a, 0),   # normal-tiny a
                      (random.getrandbits(1) << 15) | b)            # subnormal b
        push_pair('a', (random.getrandbits(1) << 15) | a,
                      bias_normal(random.choice([0,1,2,7,15]), b, random.getrandbits(1)))
        push_pair('a', bias_normal(random.choice([0,1,2,7,15]), a, random.getrandbits(1)),
                      (random.getrandbits(1) << 15) | b)

# 3) exponent sweep around the subnormal/overflow boundaries for MULTIPLY
for ea in range(0, 15):
    for eb in (0, 1, 2, 7, 14, 15):
        for _ in range(6):
            push_pair('m', bias_normal(ea, random.getrandbits(10), random.getrandbits(1)),
                          bias_normal(eb, random.getrandbits(10), random.getrandbits(1)))

# 4) exponent sweep around cancel/align boundaries for ADD (incl. exact ties x + -x)
for ea in range(0, 15):
    for eb in (0, 1, 2, 7, 14, 15):
        for _ in range(6):
            x = bias_normal(ea, random.getrandbits(10), random.getrandbits(1))
            push_pair('a', x, ((x >> 15) ^ 1) << 15 | (x & 0x7FFF))   # opposite sign same exp
        push_pair('a', bias_normal(ea, 0x2AB, 0), bias_normal(eb, 0x2AB, 1))
        push_pair('a', bias_normal(ea, 0x3FF, 0), bias_normal(eb, 0x3FF, 1))

# 5) +/- zeros
for _ in range(200):
    push_pair('m', random.choice([0x0000, 0x8000]), rand_fp16())
    push_pair('a', random.choice([0x0000, 0x8000]), rand_fp16())
    push_pair('a', rand_fp16(), random.choice([0x0000, 0x8000]))
push_pair('a', 0x0000, 0x8000)
push_pair('a', 0x8000, 0x0000)
push_pair('m', 0x8000, 0x8000)

def dump():
    with open(os.path.join(OUT, 'vec_mult_ab.mem'), 'w') as fa, \
         open(os.path.join(OUT, 'vec_mult_exp.mem'), 'w') as fe:
        for (x, y), r in zip(ab_m, exp_m):
            fa.write("%04X %04X\n" % (x, y)); fe.write("%04X\n" % r)
    with open(os.path.join(OUT, 'vec_add_ab.mem'), 'w') as fa, \
         open(os.path.join(OUT, 'vec_add_exp.mem'), 'w') as fe:
        for (x, y), r in zip(ab_a, exp_a):
            fa.write("%04X %04X\n" % (x, y)); fe.write("%04X\n" % r)
    print("mult vectors:", len(ab_m), " add vectors:", len(ab_a))

dump()
