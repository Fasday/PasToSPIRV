"""Audit of the 1.4 value operations: random programs executed on Vulkan and compared
with an independent Python model. Covers vector constructors mixing scalars and
vectors (with component conversions), ArithmeticShiftRight on Integer vectors with
scalar/vector Integer/Cardinal counts, FloorFloat and RoundFloat. All operands come
from buffers, so neither the compiler (O1) nor the driver can fold them. Conversions
stay exact and defined; RoundFloat never sees a halfway value (its direction is not
specified)."""
from __future__ import annotations

import argparse
import math
from pathlib import Path
import random
import struct
import subprocess

from vulkan_smoke import VulkanRuntime

GROUP = 64
INTS, FLOATS = 16, 16
NAMES = {'i': 'Integer', 'u': 'Cardinal', 'f': 'Single'}


def w32(value):
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value >> 31 else value


def type_name(kind, width):
    return NAMES[kind] + (str(width) if width > 1 else '')


class Node:
    def __init__(self, kind, width, source, evaluate):
        self.kind, self.width, self.source, self.evaluate = kind, width, source, evaluate


def convert(value, source, target):
    if source == target:
        return value
    if target == 'f':
        return float(value)  # |value| < 2**24 by construction: exact
    if source == 'f':
        result = int(value)  # truncation toward zero; in range by construction
        return result & 0xFFFFFFFF if target == 'u' else result
    return value & 0xFFFFFFFF if target == 'u' else w32(value)


class Generator:
    def __init__(self, rng):
        self.rng = rng

    def int_leaf(self, small=False):
        slot = self.rng.randrange(INTS)
        if small:
            return Node('i', 1, f'(In[Base + {slot}] and 1048575)', lambda env, s=slot: env['ints'][s] & 1048575)
        return Node('i', 1, f'In[Base + {slot}]', lambda env, s=slot: env['ints'][s])

    def float_leaf(self, nonnegative=False):
        slot = self.rng.randrange(FLOATS)
        if nonnegative:
            return Node('f', 1, f'Abs(InF[FBase + {slot}])', lambda env, s=slot: abs(env['floats'][s]))
        return Node('f', 1, f'InF[FBase + {slot}]', lambda env, s=slot: env['floats'][s])

    def scalar(self, target):
        """A scalar of any numeric type whose conversion to target is exact and defined."""
        choice = self.rng.randrange(6)
        if choice == 0:
            value = self.rng.randrange(0, 2000)
            return Node('i', 1, str(value), lambda env, v=value: v)
        if choice == 1:
            leaf = self.int_leaf(small=True)
            return Node('u', 1, f'Cardinal({leaf.source})', leaf.evaluate)
        if choice in (2, 3):
            return self.float_leaf(nonnegative=(target == 'u'))
        if target == 'f':
            leaf = self.int_leaf(small=True)
            if self.rng.random() < 0.5:
                return Node('i', 1, f'(0 - {leaf.source})', lambda env, l=leaf: -l.evaluate(env))
            return leaf
        return self.int_leaf()  # full range: an integer target keeps the bit pattern

    def vector(self, target, width, depth=0):
        if width == 1:
            leaf = self.scalar(target)
            return Node(target, 1, f'{NAMES[target]}({leaf.source})',
                        lambda env, l=leaf: [convert(l.evaluate(env), l.kind, target)])
        parts, remaining = [], width
        while remaining:
            size = self.rng.choice([n for n in (1, 1, 2, 3) if n <= remaining and n < width])
            parts.append(size)
            remaining -= size
        items = []
        for size in parts:
            if size == 1:
                leaf = self.scalar(target)
                items.append((leaf.source, lambda env, l=leaf: [convert(l.evaluate(env), l.kind, target)]))
                continue
            inner_kind = self.rng.choice('iuf') if depth < 2 else target
            if target == 'u' and inner_kind == 'f':
                inner_kind = 'u'
            if target == 'f' and inner_kind in 'iu':
                inner = self.small_int_vector(inner_kind, size)
            elif target in 'iu' and inner_kind == 'f':
                inner = self.float_vector(size, nonnegative=(target == 'u'))
            else:
                inner = self.vector(inner_kind, size, depth + 1)
            items.append((inner.source, lambda env, n=inner: [convert(v, n.kind, target) for v in n.evaluate(env)]))
        source = f"{type_name(target, width)}({', '.join(text for text, _ in items)})"
        return Node(target, width, source, lambda env, it=items: [v for _, f in it for v in f(env)])

    def small_int_vector(self, kind, width):
        leaves = [self.int_leaf(small=True) for _ in range(width)]
        return Node(kind, width, f"{type_name(kind, width)}({', '.join(l.source for l in leaves)})",
                    lambda env, ls=leaves: [l.evaluate(env) for l in ls])

    def float_vector(self, width, nonnegative=False):
        leaves = [self.float_leaf(nonnegative) for _ in range(width)]
        if width == 1:
            return Node('f', 1, f'Single({leaves[0].source})', lambda env, l=leaves[0]: [l.evaluate(env)])
        return Node('f', width, f"{type_name('f', width)}({', '.join(l.source for l in leaves)})",
                    lambda env, ls=leaves: [l.evaluate(env) for l in ls])

    def shift(self, width):
        base = self.vector('i', width)
        form = self.rng.randrange(4)
        if form < 2 or width == 1:
            count = self.int_leaf()
            counts = lambda env, c=count: [c.evaluate(env)] * width  # noqa: E731
            text = count.source if form != 1 else f'Cardinal({count.source})'
        else:
            vector = self.vector('i' if form == 2 else 'u', width)
            counts, text = vector.evaluate, vector.source
        return Node('i', width, f'ArithmeticShiftRight({base.source}, {text})',
                    lambda env, b=base, c=counts: [w32(v) >> (n & 31) for v, n in zip(b.evaluate(env), c(env))])

    def rounding(self, width):
        base = self.float_vector(width)
        if self.rng.random() < 0.5:
            return Node('f', width, f'FloorFloat({base.source})',
                        lambda env, b=base: [float(math.floor(v)) for v in b.evaluate(env)])
        return Node('f', width, f'RoundFloat({base.source})',
                    lambda env, b=base: [float(math.floor(v + 0.5)) for v in b.evaluate(env)])


def program(rng, statements):
    generator = Generator(rng)
    nodes = []
    for _ in range(statements):
        roll = rng.random()
        if roll < 0.55:
            nodes.append(generator.vector(rng.choice('iuf'), rng.choice((2, 3, 4, 4))))
        elif roll < 0.85:
            nodes.append(generator.shift(rng.choice((1, 2, 3, 4))))
        else:
            nodes.append(generator.rounding(rng.choice((1, 2, 3, 4))))
    lines = []
    for index, node in enumerate(nodes):
        pad = ', '.join(['0'] * (4 - node.width))
        if node.kind == 'f':
            value = node.source if node.width == 4 else f'Single4({node.source}, {pad})'
            lines += [f'  OutF[OBase + {index}] := {value};', f'  OutI[OBase + {index}] := Integer4(0);']
        else:
            inner = node.source if node.width == 4 else f'{type_name(node.kind, 4)}({node.source}, {pad})'
            value = inner if node.kind == 'i' else f'Integer4({inner})'
            lines += [f'  OutI[OBase + {index}] := {value};', f'  OutF[OBase + {index}] := Single4(0.0);']
    text = f"""var
  [Binding(0,0), ReadOnly] In: array of Integer;
  [Binding(0,1), ReadOnly] InF: array of Single;
  [Binding(0,2), WriteOnly] OutI: array of Integer4;
  [Binding(0,3), WriteOnly] OutF: array of Single4;

[LocalSize({GROUP},1,1)]
procedure Main;
var
  Base, FBase, OBase: Integer;
begin
  Base := Integer(GlobalInvocationID.X) * {INTS};
  FBase := Integer(GlobalInvocationID.X) * {FLOATS};
  OBase := Integer(GlobalInvocationID.X) * {statements};
""" + '\n'.join(lines) + '\nend;\n'
    return text, nodes


def main(programs, seed, statements=12):
    root = Path(__file__).resolve().parents[1]
    output = root / 'build/audit-vector-ops' / f'{seed}-{programs}'
    output.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    edges = [0, 1, -1, 31, 32, 33, 63, -31, -32, -33, 2147483647, -2147483648, 255, 256, -65536]
    compared = 0
    failures = []
    with VulkanRuntime() as runtime:
        for index in range(programs):
            text, nodes = program(rng, statements)
            ints = [rng.choice(edges) if rng.random() < 0.35 else w32(rng.getrandbits(32)) for _ in range(GROUP * INTS)]
            floats = []
            for _ in range(GROUP * FLOATS):
                quarters = rng.randrange(-(1 << 20), 1 << 20)
                floats.append((quarters + (quarters % 4 == 2)) / 4.0)  # multiples of 1/4, never halfway
            source = output / f'program{index}.pas'
            source.write_text(text, encoding='utf-8')
            expected = []
            for k in range(GROUP):
                env = {'ints': ints[k * INTS:(k + 1) * INTS], 'floats': floats[k * FLOATS:(k + 1) * FLOATS]}
                for node in nodes:
                    values = node.evaluate(env)
                    if node.kind == 'f':
                        expected.append(('f', [struct.unpack('<f', struct.pack('<f', v))[0] for v in values]))
                    else:
                        expected.append(('i', [w32(int(v)) for v in values]))
            for optimize in (False, True):
                spv = output / f'program{index}_O{int(optimize)}.spv'
                args = [str(root / 'build/bin/PasToSPIRV.exe'), 'compile', str(source), '-o', str(spv)]
                if optimize:
                    args.append('-O1')
                result = subprocess.run(args, capture_output=True, text=True, encoding='utf-8')
                if result.returncode:
                    failures.append(f'program{index}: compile error {result.stderr.strip()[-300:]}')
                    break
                valid = subprocess.run(['spirv-val', '--target-env', 'vulkan1.0', str(spv)],
                                       capture_output=True, text=True)
                if valid.returncode:
                    failures.append(f'program{index} O{int(optimize)}: invalid SPIR-V {valid.stdout}{valid.stderr}')
                    break
                count = GROUP * statements
                got = runtime.run(spv, {'In': struct.pack(f'<{len(ints)}i', *ints),
                                        'InF': struct.pack(f'<{len(floats)}f', *floats),
                                        'OutI': bytes(count * 16), 'OutF': bytes(count * 16)}, b'', 1)
                got_i = struct.unpack(f'<{count * 4}i', got['OutI'])
                got_f = struct.unpack(f'<{count * 4}f', got['OutF'])
                for slot, (kind, values) in enumerate(expected):
                    actual = list((got_f if kind == 'f' else got_i)[slot * 4:slot * 4 + len(values)])
                    compared += len(values)
                    if actual != values:
                        failures.append(f'program{index} O{int(optimize)} invocation {slot // statements}: '
                                        f'{nodes[slot % statements].source}: GPU {actual}, model {values}')
                        break
    if failures:
        for line in failures[:20]:
            print(line)
        raise SystemExit(f'FAIL: {len(failures)} failing program runs')
    print(f'PASS: {programs} random vector programs x {GROUP} invocations x O0/O1, '
          f'{compared} component values compared with the model, seed={seed}.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--programs', type=int, default=40)
    parser.add_argument('--seed', type=int, default=141001)
    args = parser.parse_args()
    main(args.programs, args.seed)
