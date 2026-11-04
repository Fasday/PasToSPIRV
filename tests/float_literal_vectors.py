"""Regenerates tests/fixtures/float_literals.txt from an exact rational oracle.

Each line: <decimal literal> TAB <expected binary32 bits as 8 hex digits | inf>.
The oracle rounds the exact value once to nearest-even binary32 (no Double detour).
"""
from fractions import Fraction
from pathlib import Path
import random
import struct

LIMIT = 1 << 24


def f32_bits(text):
    mantissa, _, exponent = text.lower().partition('e')
    if not mantissa.replace('.', '').strip('0'):
        return 0
    if exponent and abs(int(exponent)) > 1000:  # avoid materialising 10**huge
        return 0 if int(exponent) < 0 else None
    value = Fraction(text)
    if value == 0:
        return 0
    exponent = value.numerator.bit_length() - value.denominator.bit_length()
    b = max(exponent - 24, -149)
    while True:
        scaled = value / Fraction(2) ** b
        m = scaled.numerator // scaled.denominator
        if m >= LIMIT:
            b += 1
            continue
        break
    rest = scaled - m
    if rest > Fraction(1, 2) or (rest == Fraction(1, 2) and m & 1):
        m += 1
    if m == LIMIT:
        m, b = LIMIT >> 1, b + 1
    if b > 104:
        return None
    return ((b + 149) << 23) + m


def exact_decimal(value):
    """Exact finite decimal for a dyadic rational, in literal grammar."""
    whole, rest = divmod(value.numerator, value.denominator)
    digits = []
    while rest:
        rest *= 10
        digit, rest = divmod(rest, value.denominator)
        digits.append(str(digit))
    return f'{whole}.{"".join(digits) or "0"}'


def bits_value(bits):
    exponent, mantissa = bits >> 23, bits & 0x7FFFFF
    if exponent == 0:
        return Fraction(mantissa, 1 << 149)
    return Fraction(mantissa | 0x800000) * Fraction(2) ** (exponent - 150)


def main():
    rng = random.Random(0x5EED1E)
    cases = ['3.4028235e38', '3.4028234663852886e38', '3.40282356e38', '3.4028236e38',
             '1.0000000596046447753906250001', '1.000000059604644775390625',
             '4.2448189515961663e-31', '7.006492321624086e-46', '7.006492321624085e-46',
             '1.401298464324817e-45', '1e-50', '0e999999999999', '0.0', '1e-999999999999',
             '1.17549435e-38', '1.1754942e-38', '16777217.0', '16777219.0', '0.1', '1e39']
    for _ in range(4000):
        digits = ''.join(rng.choice('0123456789') for _ in range(rng.randint(1, 40))).lstrip('0') or '1'
        point = rng.randint(1, len(digits))
        text = digits[:point] + '.' + (digits[point:] or '0')
        cases.append(f'{text}e{rng.randint(-50, 38)}')
    for _ in range(1500):
        bits = rng.randrange(0, 0x7F7FFFFF)
        low, high = bits_value(bits), bits_value(bits + 1)
        middle = (low + high) / 2
        exact = exact_decimal(middle)
        cases.append(exact)                  # exact tie: nearest-even
        cases.append(exact + '000000000001')  # just above the tie
        below = middle - (high - low) / 2 ** 40
        cases.append(exact_decimal(below))
    top = bits_value(0x7F7FFFFF)
    edge = top + (bits_value(0x7F7FFFFF) - bits_value(0x7F7FFFFE)) / 2
    cases += [exact_decimal(edge), exact_decimal(edge) + '1', exact_decimal(edge - Fraction(1, 2 ** 80))]
    half_min = Fraction(1, 2 ** 150)
    cases += [exact_decimal(half_min), exact_decimal(half_min) + '1', exact_decimal(half_min * 3)]
    lines = []
    for text in cases:
        bits = f32_bits(text)
        if bits is not None and bits < 0x7F800000 and text.count('e') == 0 and len(text) < 40:
            # Sanity check of the oracle against IEEE double where double rounding is harmless.
            if len(text.replace('.', '').lstrip('0')) <= 7:
                assert struct.unpack('<I', struct.pack('<f', float(text)))[0] == bits, text
        lines.append(f'{text}\t{"inf" if bits is None else format(bits, "08X")}')
    target = Path(__file__).resolve().parent / 'fixtures' / 'float_literals.txt'
    target.write_text('\n'.join(lines) + '\n', encoding='ascii')
    print(f'Wrote {len(lines)} vectors to {target}')


if __name__ == '__main__':
    main()
