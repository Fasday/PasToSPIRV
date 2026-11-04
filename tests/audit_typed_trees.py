"""Re-audit: random typed expression trees, host constant folding vs Vulkan vs oracle.

Each tree is evaluated four ways and compared with an exact Python model:
  * typed `const` declaration (host PTS.ConstEval),
  * literal leaves in Main at O0 (GPU/driver) and at O1 (host folding of integer trees),
  * buffer-loaded leaves (always computed on the GPU).
Float trees use only + - * and casts (StrictFloat): native division/sqrt are not
claimed to be correctly rounded and are excluded. Undefined operations are avoided.
"""
from __future__ import annotations

import argparse
from fractions import Fraction
import math
from pathlib import Path
import random
import struct
import subprocess

from vulkan_extended import ExtendedRuntime

INTS = {'Byte': (8, False), 'Word': (16, False), 'Integer': (32, True),
        'Cardinal': (32, False), 'Int64': (64, True), 'UInt64': (64, False)}
FLOATS = {'Single': 32, 'Double': 64}
MASK64 = (1 << 64)-1


def wrap(value, t):
    width, signed = INTS[t]
    value &= (1 << width)-1
    return value-(1 << width) if signed and value >> (width-1) else value


def round_float(value: Fraction, width):
    """Exact rational -> IEEE nearest-even, returned as an exact Python float."""
    if value == 0:
        return 0.0
    p, emin = (24, -126) if width == 32 else (53, -1022)
    sign = -1 if value < 0 else 1
    value = abs(value)
    n, d = value.numerator, value.denominator
    e = n.bit_length()-d.bit_length()
    if (n < d << e) if e >= 0 else (n << -e < d):
        e -= 1
    scale = max(e, emin)-(p-1)
    num, den = n << max(-scale, 0), d << max(scale, 0)
    q, r = divmod(num, den)
    if 2*r > den or (2*r == den and q & 1):
        q += 1
    result = math.ldexp(q, scale)
    assert not math.isinf(result)
    return sign*result


def fbits(value, width):
    if width == 32:
        return struct.unpack('<I', struct.pack('<f', value))[0]
    return struct.unpack('<Q', struct.pack('<d', value))[0]


def float_literal(value, width):
    # repr() of a binary32 value is an exact-enough shortest decimal for binary64;
    # parse it back through the binary32 rounding the compiler applies to plain literals.
    text = repr(abs(value))
    if 'inf' in text or 'nan' in text:
        raise AssertionError(value)
    if width == 64:
        exact = Fraction(abs(value))
        text = f'{exact.numerator}' if exact.denominator == 1 else None
        if text is None:
            # Exact decimal expansion of a dyadic rational.
            den = exact.denominator
            shift = den.bit_length()-1
            digits = exact.numerator * 5**shift
            text = f'{digits}e-{shift}'
        text += 'd'
    if math.copysign(1, value) < 0:
        return f'(-{text})'
    return text


class Gen:
    def __init__(self, rng, mode):
        self.rng, self.mode = rng, mode
        self.int_inputs: list[int] = []
        self.real_inputs: list[float] = []
        self.intrinsic = False  # intrinsics are not constant-folded by const declarations

    def int_leaf(self, t):
        width, _ = INTS[t]
        if self.rng.random() < 0.3:
            raw = self.rng.choice([0, 1, 2, 3, (1 << width)-1, 1 << (width-1), (1 << (width-1))-1])
        else:
            raw = self.rng.getrandbits(width)
        value = wrap(raw, t)
        if self.mode == 'buffer':
            self.int_inputs.append(raw)
            return f'{t}(In[@{len(self.int_inputs)-1}])', value
        return f'{t}({value})' if value >= 0 else f'{t}(({value}))', value

    def int_expr(self, t, depth):
        width, signed = INTS[t]
        if depth == 0 or self.rng.random() < 0.2:
            return self.int_leaf(t)
        kind = self.rng.choice(['bin', 'bin', 'bin', 'shift', 'divmod', 'not', 'neg', 'cast', 'intrinsic'])
        if kind == 'cast':
            text, value = self.int_expr(self.rng.choice(list(INTS)), depth-1)
            return f'{t}({text})', wrap(value, t)
        if kind == 'intrinsic':
            self.intrinsic = True
            a_text, a = self.int_expr(t, depth-1)
            b_text, b = self.int_expr(t, depth-1)
            name = self.rng.choice(['Min', 'Max', 'Abs', 'Clamp'])
            if name == 'Min':
                return f'Min({a_text}, {b_text})', min(a, b)
            if name == 'Max':
                return f'Max({a_text}, {b_text})', max(a, b)
            if name == 'Abs':
                return f'Abs({a_text})', wrap(abs(a), t)
            c_text, c = self.int_expr(t, depth-1)
            lo, hi = min(b, c), max(b, c)
            return (f'Clamp({a_text}, Min({b_text}, {c_text}), Max({b_text}, {c_text}))',
                    min(max(a, lo), hi))
        if kind == 'not':
            text, value = self.int_expr(t, depth-1)
            return f'(not {text})', wrap(~value, t)
        if kind == 'neg':
            text, value = self.int_expr(t, depth-1)
            if not signed:
                return text, value
            return f'(-{text})', wrap(-value, t)
        a_text, a = self.int_expr(t, depth-1)
        if kind == 'shift':
            c_text, c = self.int_expr(self.rng.choice(list(INTS)), depth-1)
            count = c & (width-1)
            if self.rng.random() < 0.5:
                return f'({a_text} shl {c_text})', wrap(a << count, t)
            return f'({a_text} shr {c_text})', wrap((a & ((1 << width)-1)) >> count, t)
        b_text, b = self.int_expr(t, depth-1)
        if kind == 'divmod':
            if signed:
                limit = (1 << (width-1))-1
                b_text, b = f'(({b_text} and {t}({limit})) or {t}(1))', (b & limit) | 1
            else:
                b_text, b = f'({b_text} or {t}(1))', b | 1
            q = abs(a)//abs(b) * (-1 if (a < 0) != (b < 0) else 1)
            if self.rng.random() < 0.5:
                return f'({a_text} div {b_text})', wrap(q, t)
            return f'({a_text} mod {b_text})', wrap(a-q*b, t)
        op = self.rng.choice(['+', '-', '*', 'and', 'or', 'xor'])
        value = {'+': a+b, '-': a-b, '*': a*b, 'and': a & b, 'or': a | b, 'xor': a ^ b}[op]
        return f'({a_text} {op} {b_text})', wrap(value, t)

    def float_leaf(self, t):
        width = FLOATS[t]
        if self.rng.random() < 0.15:
            value = self.rng.choice([0.0, -0.0, 1.0, -1.0, 0.5, 2.0**-20, 3.0])
        else:
            value = round_float(Fraction(self.rng.uniform(-1000, 1000)), 32)
        if self.mode == 'buffer':
            self.real_inputs.append(value)
            return f'{t}(R[@{len(self.real_inputs)-1}])', value
        return f'{t}({float_literal(value, width)})', value

    def float_expr(self, t, depth):
        width = FLOATS[t]
        if depth == 0 or self.rng.random() < 0.25:
            return self.float_leaf(t)
        kind = self.rng.choice(['bin', 'bin', 'bin', 'neg', 'intcast', 'fcast'])
        if kind == 'neg':
            text, value = self.float_expr(t, depth-1)
            return f'(-{text})', -value
        if kind == 'intcast':
            text, value = self.int_expr(self.rng.choice(list(INTS)), min(depth-1, 2))
            return f'{t}({text})', round_float(Fraction(value), width)
        if kind == 'fcast':
            text, value = self.float_expr('Double' if t == 'Single' else 'Single', depth-1)
            return f'{t}({text})', round_float(Fraction(value), width) if value else value
        a_text, a = self.float_expr(t, depth-1)
        b_text, b = self.float_expr(t, depth-1)
        op = self.rng.choice(['+', '-', '*'])
        if op == '*' and abs(Fraction(a)*Fraction(b)) > 2**100:
            op = '-'  # stay finite in binary32; overflow is not a compared contract here
        exact = {'+': Fraction(a)+Fraction(b), '-': Fraction(a)-Fraction(b),
                 '*': Fraction(a)*Fraction(b)}[op]
        if exact != 0:
            value = round_float(exact, width)
        elif op == '*':
            value = math.copysign(0.0, math.copysign(1, a)*math.copysign(1, b))
        else:
            sa = math.copysign(1, a) < 0
            sb = (math.copysign(1, b) < 0) != (op == '-')
            value = -0.0 if sa and sb else 0.0  # exact zero sum is +0 unless both are -0
        return f'({a_text} {op} {b_text})', value


def output_text(t, text):
    if t in INTS:
        return f'UInt64({text})'
    return f'UInt64(SingleToBits({text}))' if t == 'Single' else f'DoubleToBits({text})'


def encode(t, value):
    return value & MASK64 if t in INTS else fbits(value, FLOATS[t])


def run(count, depth, seed, root, runtime):
    output = root/'build/audit-typed-trees'/f'{seed}-{count}-{depth}'
    output.mkdir(parents=True, exist_ok=True)
    trees, int_inputs, real_inputs, consts, body = [], [], [], [], []
    picker = random.Random(seed)
    for i in range(count):
        t = picker.choice(list(INTS)+list(FLOATS))
        literal, buffered = (Gen(random.Random(seed*100003+i), m) for m in ('literal', 'buffer'))
        generate = (lambda g: g.int_expr) if t in INTS else (lambda g: g.float_expr)
        lit_text, value = generate(literal)(t, depth)
        buf_text, buf_value = generate(buffered)(t, depth)
        assert encode(t, buf_value) == encode(t, value)
        base_i, base_r = len(int_inputs), len(real_inputs)
        for k in range(len(buffered.int_inputs)-1, -1, -1):
            buf_text = buf_text.replace(f'In[@{k}]', f'In[{base_i+k}]')
        for k in range(len(buffered.real_inputs)-1, -1, -1):
            buf_text = buf_text.replace(f'R[@{k}]', f'R[{base_r+k}]')
        int_inputs += buffered.int_inputs
        real_inputs += buffered.real_inputs
        trees.append((t, lit_text, value))
        if literal.intrinsic:
            body.append(f'  O[{3*i}] := {output_text(t, lit_text)};')
        else:
            consts.append(f'  C{i}: {t} = {lit_text};')
            body.append(f'  O[{3*i}] := {output_text(t, f"C{i}")};')
        body.append(f'  O[{3*i+1}] := {output_text(t, lit_text)};')
        body.append(f'  O[{3*i+2}] := {output_text(t, buf_text)};')
    int_inputs, real_inputs = int_inputs or [0], real_inputs or [0.0]
    source = (('const\n' + '\n'.join(consts) + '\n' if consts else '') + 'var\n'
              '  [Binding(0,0),ReadOnly] In: array of UInt64;\n'
              '  [Binding(0,1),ReadOnly] R: array of Double;\n'
              '  [Binding(0,2),WriteOnly] O: array of UInt64;\n'
              '[Vulkan12,StrictFloat,LocalSize(1,1,1)]\nprocedure Main;\nbegin\n'
              + '\n'.join(body) + '\nend;\n')
    path = output/'trees.pas'
    path.write_text(source, encoding='utf-8')
    checked = 0
    for optimize in (False, True):
        module = output/f'trees_O{int(optimize)}.spv'
        args = [str(root/'build/bin/PasToSPIRV.exe'), str(path), '-o', str(module)]
        compiled = subprocess.run(args + (['-O1'] if optimize else []), capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stderr
        subprocess.run(['spirv-val', '--target-env', 'vulkan1.2', str(module)], check=True, capture_output=True)
        result = runtime.run(module, {'In': struct.pack(f'<{len(int_inputs)}Q', *int_inputs),
                                      'R': struct.pack(f'<{len(real_inputs)}d', *real_inputs),
                                      'O': bytes(3*count*8)}, b'', 1)
        actual = struct.unpack(f'<{3*count}Q', result['O'])
        for i, (t, lit_text, value) in enumerate(trees):
            want = encode(t, value)
            for slot, label in enumerate(('const', 'literal', 'buffer')):
                got = actual[3*i+slot]
                assert got == want, (f'tree {i} {t} {label} O{int(optimize)}: '
                                     f'{got:016x} != {want:016x}\n{lit_text}\n{path}')
                checked += 1
    return checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count', type=int, default=200)
    parser.add_argument('--depth', type=int, default=4)
    parser.add_argument('--seed', type=int, default=930117)
    parser.add_argument('--rounds', type=int, default=1)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    total = 0
    with ExtendedRuntime() as runtime:
        for index in range(args.rounds):
            total += run(args.count, args.depth, args.seed+index, root, runtime)
        print(f'PASS: {total} typed-tree results (const/literal/buffer x O0/O1), '
              f'{runtime.dispatches} dispatches, seed={args.seed}, rounds={args.rounds}.')


if __name__ == '__main__':
    main()
