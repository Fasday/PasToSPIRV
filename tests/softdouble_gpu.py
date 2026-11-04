"""GPU check of lib/SoftDouble.pasm against Delphi Win64 DIVSD (bit-exact,
including NaN payloads and subnormals) and an independent Fraction oracle for
finite results. Generated data goes under build/softdouble/<seed>-<count>."""
from __future__ import annotations

import argparse
from fractions import Fraction
from pathlib import Path
import random
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vulkan_smoke import compile_shader  # noqa: E402
from vulkan_extended import ExtendedRuntime  # noqa: E402

MAX_FINITE = 0x7FEFFFFFFFFFFFFF


def value(bits):
    exponent, significand = (bits >> 52) & 0x7FF, bits & ((1 << 52) - 1)
    if exponent:
        significand |= 1 << 52
    power = (exponent or 1) - 1075
    magnitude = Fraction(significand) * (Fraction(2) ** power)
    return -magnitude if bits >> 63 else magnitude


def round_fraction(x):
    """Nearest-even binary64 bits of a nonzero rational (overflow -> infinity)."""
    sign = 1 << 63 if x < 0 else 0
    x = abs(x)
    lo, hi = 0, MAX_FINITE
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if value(mid) <= x:
            lo = mid
        else:
            hi = mid - 1
    if lo == MAX_FINITE:
        limit = value(MAX_FINITE) + Fraction(2) ** 970  # half an ULP above the maximum
        return sign | (0x7FF0000000000000 if x >= limit else MAX_FINITE)
    left, right = x - value(lo), value(lo + 1) - x
    if right < left or (right == left and lo & 1):
        lo += 1
    return sign | lo


def special_values():
    values = [0, 1, 2, 3, 0x000FFFFFFFFFFFFF, 0x0008000000000000, 0x0010000000000000,
              0x0010000000000001, 0x3FF0000000000000, 0x3FF0000000000001, 0x3FEFFFFFFFFFFFFF,
              0x4000000000000000, 0x4008000000000000, 0x3FB999999999999A, MAX_FINITE,
              0x7FE0000000000000, 0x0020000000000000, 0x7FF0000000000000,
              0x7FF8000000000000, 0x7FF0000000000001, 0x7FF4000000000123, 0x7FFFFFFFFFFFFFFF,
              0x7FF8DEADBEEF0001]
    return values + [v | (1 << 63) for v in values]


def build_pairs(rng, count):
    specials = special_values()
    pairs = [(a, b) for a in specials for b in specials]
    # Subnormal results with exact ties: (2k+1) * 2^-1074 / 2^j.
    for k in range(1, 40):
        for j in (1, 2, 3, 52, 53, 54):
            pairs.append(((2 * k + 1), 0x3FF0000000000000 + (j << 52)))
    # Quotients near the overflow and underflow thresholds.
    for _ in range(400):
        a = rng.randrange(0x7FC0000000000000, MAX_FINITE + 1)
        pairs.append((a, rng.randrange(0x3F00000000000000, 0x4010000000000000)))
        a = rng.randrange(0x0000000000000001, 0x0040000000000000)
        pairs.append((a, rng.randrange(0x3FE0000000000000, 0x4340000000000000)))
        a = rng.randrange(0x3C00000000000000, 0x4000000000000000)
        pairs.append((a, rng.randrange(0x7FB0000000000000, MAX_FINITE + 1)))
    # Divisors with long runs of ones/zeros stress the digit correction.
    for _ in range(400):
        run = rng.randrange(1, 52)
        b = 0x3FF0000000000000 | (((1 << run) - 1) << (52 - run))
        a = rng.randrange(0x3FF0000000000000, 0x4000000000000000)
        pairs.append((a, b))
        pairs.append((b, a))
        pairs.append((a, 0x3FF0000000000000 | rng.choice((1, (1 << 52) - 1, 1 << 51))))
    while len(pairs) < count:
        kind = rng.randrange(4)
        if kind == 0:  # any bit patterns
            pairs.append((rng.getrandbits(64), rng.getrandbits(64)))
        elif kind == 1:  # normal values of moderate magnitude
            pairs.append((rng.randrange(0x3000000000000000, 0x5000000000000000) | (rng.getrandbits(1) << 63),
                          rng.randrange(0x3000000000000000, 0x5000000000000000) | (rng.getrandbits(1) << 63)))
        elif kind == 2:  # subnormal operands
            pairs.append((rng.randrange(1, 1 << 52), rng.randrange(1, 0x0030000000000000)))
        else:  # same significands, nearby quotients near 1
            a = rng.randrange(0x3FF0000000000000, 0x4000000000000000)
            pairs.append((a, a + rng.randrange(-4, 5)))
    return pairs[:max(count, len(pairs))]


def main(count, seed, oracle_count):
    root = Path(__file__).resolve().parents[1]
    output = root / 'build/softdouble' / f'{seed}-{count}'
    output.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    pairs = build_pairs(rng, count)
    raw = struct.pack(f'<{2 * len(pairs)}Q', *(x for pair in pairs for x in pair))
    (output / 'pairs.bin').write_bytes(raw)
    reference = root / 'build/bin/SoftDoubleCheck.exe'
    subprocess.run([str(reference), str(output / 'pairs.bin'), str(output / 'expected.bin')],
                   check=True, capture_output=True)
    expected = struct.unpack(f'<{len(pairs)}Q', (output / 'expected.bin').read_bytes())

    # The Delphi reference itself against exact rational arithmetic.
    checked = 0
    for (a, b), q in zip(pairs, expected):
        if checked >= oracle_count:
            break
        if (a >> 52) & 0x7FF == 0x7FF or (b >> 52) & 0x7FF == 0x7FF or value(a) == 0 or value(b) == 0:
            continue
        want = round_fraction(value(a) / value(b))
        if want != q:
            raise AssertionError(f'Delphi reference {a:016x}/{b:016x} = {q:016x}, oracle {want:016x}')
        checked += 1

    groups = (len(pairs) + 63) // 64
    mismatches = 0
    with ExtendedRuntime() as runtime:
        for optimize in (False, True):
            module = compile_shader(root, output, 'softdouble_div', 'tests/fixtures',
                                    include_dirs=(root / 'lib',), optimize=optimize)
            result = runtime.run(module, {'Pairs': raw, 'Quotients': bytes(8 * len(pairs)),
                                          'Values': bytes(8 * len(pairs))}, b'', groups)
            for name in ('Quotients', 'Values'):
                actual = struct.unpack(f'<{len(pairs)}Q', result[name])
                for (a, b), got, want in zip(pairs, actual, expected):
                    if got != want:
                        mismatches += 1
                        if mismatches <= 10:
                            print(f'MISMATCH O{int(optimize)} {name}: {a:016x} / {b:016x} = '
                                  f'{got:016x}, Delphi {want:016x}')
    if mismatches:
        raise AssertionError(f'{mismatches} SoftDouble mismatches')
    print(f'PASS: SoftDouble division bit-exact with Delphi DIVSD: {len(pairs)} pairs x '
          f'(SoftDivBits, SoftDiv) x O0/O1, {checked} finite results confirmed by a Fraction oracle, '
          f'seed={seed}; {runtime.dispatches} dispatches.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--count', type=int, default=65536)
    parser.add_argument('--seed', type=int, default=730511)
    parser.add_argument('--oracle', type=int, default=4000)
    arguments = parser.parse_args()
    main(arguments.count, arguments.seed, arguments.oracle)
