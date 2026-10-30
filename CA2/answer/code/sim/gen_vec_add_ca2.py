#!/usr/bin/env python3
# Golden vectors for the CA2 truncating adder (independent exact-arithmetic model).
# Test protocol (same as tb_fp16_add_unit): clear accum, add a, add b -> acc = a (flushed) + b (flushed).
# Writes vec_add_ab.mem / vec_add_exp.mem next to this script.
import random, os
from fractions import Fraction
random.seed(2026)
OUT = os.path.dirname(os.path.abspath(__file__))

def val(x):
    e = (x >> 10) & 31
    if e == 0 or (x & 1023) == 0: return Fraction(0)   # exp==0 or mantissa==0 -> 0
    m = Fraction(1024 + (x & 1023), 1024)
    v = m * (Fraction(2) ** (e - 15))
    return -v if x >> 15 else v

def pack(v):
    if v == 0: return 0x0000
    s = 1 if v < 0 else 0
    a = abs(v)
    e = 0
    while a >= 2: a /= 2; e += 1
    while a < 1:  a *= 2; e -= 1
    ef = e + 15
    if ef >= 31: return (s << 15) | (31 << 10)      # overflow
    if ef <= 0:  return 0x0000                      # underflow
    frac = int((a - 1) * 1024)                      # truncate
    return (s << 15) | (ef << 10) | frac

def ref_add(a, b): return pack(val(a) + val(b))

def rnd():
    e = random.choice([0,1,1,2,3,5,7,10,14,15,15,16,18,20,24,28,29,30,30])
    return (random.getrandbits(1) << 15) | (e << 10) | random.getrandbits(10)

pairs = [(rnd(), rnd()) for _ in range(20000)]
for _ in range(3000):                       # same exponent / near cancellation
    x = rnd(); y = x ^ 0x8000
    pairs.append((x, y ^ random.choice([0, 0, 1, 2, 0x3FF])))
for _ in range(2000):                       # close exponents
    e = random.randint(1, 29)
    x = (random.getrandbits(1) << 15) | (e << 10) | random.getrandbits(10)
    y = (random.getrandbits(1) << 15) | ((e + random.choice([-1,0,1])) << 10 & 0x7C00) | random.getrandbits(10)
    pairs.append((x, y))
pairs += [(0x7800,0x7800),(0xF800,0xF800),(0x7BFF,0x7BFF),(0x0400,0x8400),(0x0400,0x0400),
          (0x3C00,0xBC00),(0x3C00,0x3C00),(0x0000,0x8000),(0x0001,0x3C00),(0x3C00,0x03FF)]
with open(os.path.join(OUT,'vec_add_ab.mem'),'w') as fa, open(os.path.join(OUT,'vec_add_exp.mem'),'w') as fe:
    for a, b in pairs:
        fa.write("%04X %04X\n" % (a, b)); fe.write("%04X\n" % ref_add(a, b))
print("add vectors:", len(pairs))
