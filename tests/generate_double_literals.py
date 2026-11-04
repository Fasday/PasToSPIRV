"""Independent Fraction/binary-search oracle. Generated data goes under build/."""
from decimal import Decimal, localcontext
from fractions import Fraction
from pathlib import Path
import random


def value(bits):
    exponent, significand = bits >> 52, bits & ((1 << 52)-1)
    if exponent:
        significand |= 1 << 52
    power = (exponent or 1) - 1023 - 52
    return Fraction(significand * (1 << max(power, 0)), 1 << max(-power, 0))


def oracle(text):
    x = Fraction(text)
    maximum = (0x7ff << 52)-1
    if x >= (value(maximum) + Fraction(1 << 1024)) / 2:
        return 'overflow'
    lo, hi = 0, maximum
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if value(mid) <= x:
            lo = mid
        else:
            hi = mid-1
    if lo == maximum:
        return f'{lo:016x}'
    left, right = x-value(lo), value(lo+1)-x
    if right < left or (right == left and lo & 1):
        lo += 1
    return f'{lo:016x}'


def main():
    root = Path(__file__).resolve().parents[1]
    output = root / 'build/tests/double_literals.txt'
    output.parent.mkdir(parents=True, exist_ok=True)
    texts = ['0.0', '1e309', '1e-400', '1e-300', '5e-324', '2.4703282292062327e-324',
             '2.4703282292062328e-324', '1.7976931348623157e308', '1.7976931348623159e308']
    rng = random.Random(487651)
    with localcontext() as ctx:
        ctx.prec = 2000
        for bits in [0, 1, (1 << 52)-1, 1 << 52, 0x3fefffffffffffff,
                     0x3ff0000000000000, 0x7feffffffffffffe] + [rng.randrange(0x7fefffffffffffff) for _ in range(40)]:
            midpoint = (value(bits)+value(bits+1))/2
            decimal = Decimal(midpoint.numerator) / Decimal(midpoint.denominator)
            epsilon = Decimal(10) ** (decimal.adjusted()-1250)
            for v in (decimal-epsilon, decimal, decimal+epsilon):
                texts.append(format(v, 'f'))
        for _ in range(100):
            texts.append(str(rng.randrange(1, 10**40)) + 'e' + str(rng.randrange(-360, 280)))
    output.write_text(''.join(f'{t}\t{oracle(t)}\n' for t in texts), encoding='ascii')
    print(f'Generated {len(texts)} independent binary64 literal cases: {output}')


if __name__ == '__main__':
    main()
