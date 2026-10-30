import argparse
import os
import sys
import numpy as np

def to_float(h):
    return float(np.frombuffer(h.to_bytes(2, 'little'), dtype=np.float16)[0])

def S(h):
    if h is None:
        return '----'
    v = to_float(h)
    return '%04X(%s)' % (h, '%.6g' % v)

def X(h):
    return '----' if h is None else '%04X' % h

class HwArith:
    def __init__(self):
        pass

    def _to_np(self, h):
        return np.frombuffer(h.to_bytes(2, 'little'), dtype=np.float16)[0]

    def _to_int(self, f):
        return int.from_bytes(f.tobytes(), 'little')

    def mul(self, a, b):
        fa = self._to_np(a)
        fb = self._to_np(b)
        return self._to_int(fa * fb)

    def add(self, a, b):
        fa = self._to_np(a)
        fb = self._to_np(b)
        return self._to_int(fa + fb)

def relu(h):
    f = to_float(h)
    if np.isnan(f):
        return h
    return h if f > 0 else 0

def read_mem(path):
    vals = []
    with open(path) as fh:
        for line in fh:
            for c in ('//', '#'):
                line = line.split(c, 1)[0]
            for tok in line.replace(',', ' ').split():
                if tok.startswith('@'):
                    continue
                vals.append(int(tok.replace('_', ''), 16) & 0xFFFF)
    return vals

def need(path, n, name, multiple=False):
    if not os.path.exists(path):
        sys.exit(f'ERROR: {name} not found ({path})')
    v = read_mem(path)
    if (multiple and len(v) % n) or (not multiple and len(v) != n):
        sys.exit(f'ERROR: {name} size mismatch')
    return v

def write_mem(path, vals):
    with open(path, 'w') as fh:
        for v in vals:
            fh.write('%04X\n' % v)

def argmax(vals):
    best, bi = None, 0
    for i, h in enumerate(vals):
        f = to_float(h)
        if np.isnan(f):
            continue
        if best is None or f > best:
            best, bi = f, i
    return bi

def run_network(bias_mode, W1, W2, xin, b, index):
    LANES = 7
    hw = HwArith()
    act = [0] * 8
    final2 = [0] * 10
    T = []
    blocks = [[None] * LANES, [None] * LANES]
    block_owner = [None, None]
    gr = 0

    T.append(f'FCNN golden debug trace  (image {index}, Bias mode: {bias_mode.upper()})')
    T.append('arithmetic: IEEE 754 Float16 (via numpy)')
    T.append('ping-pong rule: global row number k is written into block A if k is even, B if odd; '
             'the adder drains the block that was just filled while the multiplier fills the other one')
    T.append('')

    for layer, Wm, n_in, n_neu, xs_all, bias_list in ((1, W1, 784, 8, xin, b[:8]), (2, W2, 8, 10, act, b[8:])):
        rows = -(-n_in // LANES)
        T.append('#' * 100)
        T.append(f'# LAYER {layer}: {n_neu} neurons x {n_in} inputs  ({rows} SRAM rows per neuron)')
        T.append('#' * 100)
        for j in range(n_neu):
            bias = bias_list[j]
            acc = bias if bias_mode == 'first' else 0
            T.append('')
            T.append(f'=== L{layer} neuron {j} | bias C{j} = {S(bias)} | accumulator starts at {S(acc)} ===')
            for r in range(rows):
                lanes = min(LANES, n_in - r * LANES)
                wv = Wm[j][r * LANES:r * LANES + lanes]
                xv = xs_all[r * LANES:r * LANES + lanes]
                blk = gr % 2
                P = [hw.mul(p, q) for p, q in zip(wv, xv)]
                blocks[blk] = P + [None] * (LANES - lanes)
                block_owner[blk] = gr
                T.append(f'--- L{layer} n{j} row {r}/{rows}  (SRAM row, global row #{gr}) ---')
                T.append('  SRAM weights W : ' + ' '.join(X(v) for v in wv + [None] * (LANES - lanes)))
                T.append('  inputs x       : ' + ' '.join(X(v) for v in xv + [None] * (LANES - lanes)))
                T.append('  MULT outputs p : ' + ' '.join(X(v) for v in blocks[blk]) +
                         '   (p_i = W_i * x_i)')
                T.append('  PING-PONG      : select=%d  multiplier fills block %s with row #%d; adder drains block %s'
                         % (blk, 'AB'[blk], gr, 'AB'[blk]))
                for bi_ in (0, 1):
                    T.append('                   block %s = [%s] %s' % (
                        'AB'[bi_], ' '.join(X(v) for v in blocks[bi_]),
                        f'(row #{block_owner[bi_]})' if block_owner[bi_] is not None else '(empty)'))
                for lane in range(lanes):
                    before = acc
                    acc = hw.add(acc, P[lane])
                    T.append(f'  ADDER step {lane}    : acc {X(before)} + p{lane} {X(P[lane])} = {X(acc)}')
                T.append(f'  acc after row  : {S(acc)}')
                gr += 1
            if bias_mode == 'last':
                before = acc
                acc = hw.add(acc, bias)
                T.append(f'  BIAS add       : acc {X(before)} + C{j} {X(bias)} = {X(acc)}')
            if layer == 1:
                act[j] = relu(acc)
                T.append(f'>>> L1 neuron {j} done: H = {S(acc)} -> ReLU -> {S(act[j])}  (regfile[{j}])')
            else:
                final2[j] = acc
                T.append(f'>>> L2 neuron {j} done: H{j} = {S(acc)}  (output)')
        if layer == 1:
            T.append('')
            T.append('REGISTER FILE after layer 1: ' + ' '.join(X(v) for v in act) + ' ---- ----')

    digit = argmax(final2)
    T.append('')
    T.append('FINAL OUTPUTS: ' + ' '.join(X(v) for v in final2))
    T.append(f'predicted digit (argmax): {digit}')
    
    return act, final2, T

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--weights', default='weights.mem')
    ap.add_argument('--bias', default='bias.mem')
    ap.add_argument('--input', default='input.mem')
    ap.add_argument('--index', type=int, default=0)
    ap.add_argument('--outdir', default='debug_out')
    ap.add_argument('--w-layout', default='neuron-major', choices=['neuron-major', 'input-major'])
    a = ap.parse_args()

    w = need(a.weights, 6352, 'weights')
    b = need(a.bias, 18, 'bias')
    img = need(a.input, 784, 'input', True)
    xin = img[a.index * 784:(a.index + 1) * 784]
    w1, w2 = w[:6272], w[6272:]
    
    if a.w_layout == 'neuron-major':
        W1 = [w1[j * 784:(j + 1) * 784] for j in range(8)]
        W2 = [w2[j * 8:(j + 1) * 8] for j in range(10)]
    else:
        W1 = [[w1[i * 8 + j] for i in range(784)] for j in range(8)]
        W2 = [[w2[i * 10 + j] for i in range(8)] for j in range(10)]

    os.makedirs(a.outdir, exist_ok=True)

    print("=== Bias Added FIRST ===")
    act_first, final2_first, T_first = run_network('first', W1, W2, xin, b, a.index)
    print("Predicted digit:", argmax(final2_first))
    write_mem(os.path.join(a.outdir, 'l1_model_output_first.mem'), act_first)
    write_mem(os.path.join(a.outdir, 'l2_model_output_first.mem'), final2_first)
    with open(os.path.join(a.outdir, 'debug_trace_first.txt'), 'w') as fh:
        fh.write('\n'.join(T_first) + '\n')
    
    print("\n=== Bias Added LAST ===")
    act_last, final2_last, T_last = run_network('last', W1, W2, xin, b, a.index)
    print("Predicted digit:", argmax(final2_last))
    write_mem(os.path.join(a.outdir, 'l1_model_output_last.mem'), act_last)
    write_mem(os.path.join(a.outdir, 'l2_model_output_last.mem'), final2_last)
    with open(os.path.join(a.outdir, 'debug_trace_last.txt'), 'w') as fh:
        fh.write('\n'.join(T_last) + '\n')

    print(f"\nFiles saved in {a.outdir}/ :")
    print(" - debug_trace_first.txt / debug_trace_last.txt")
    print(" - l1_model_output_first.mem / l1_model_output_last.mem")
    print(" - l2_model_output_first.mem / l2_model_output_last.mem")

if __name__ == '__main__':
    main()