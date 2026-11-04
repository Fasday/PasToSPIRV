"""Deterministic independent 32-bit arithmetic oracle vs O0/O1/const SPIR-V on Vulkan."""
import argparse
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from vulkan_smoke import VulkanRuntime

MASK = 0xFFFFFFFF


def signed(bits):
    return bits if bits < 0x80000000 else bits - 0x100000000


def generate(rng, unsigned, depth):
    name = 'Cardinal' if unsigned else 'Integer'
    if depth == 0 or rng.randrange(5) == 0:
        bits = rng.choice((0, 1, 2, MASK, 0x80000000, 0x7FFFFFFF, rng.getrandbits(32)))
        return f'{name}(${bits:08X})', bits
    left, a = generate(rng, unsigned, depth - 1)
    right, b = generate(rng, unsigned, depth - 1)
    op = rng.choice(('+', '-', '*', 'div', 'mod', 'and', 'or', 'xor', 'shl', 'shr'))
    x, y = (a, b) if unsigned else (signed(a), signed(b))
    if op in ('div', 'mod') and (y == 0 or (x == -2147483648 and y == -1)):
        right, b, y = f'{name}(3)', 3, 3
    if op == '+': result = a + b
    elif op == '-': result = a - b
    elif op == '*': result = a * b
    elif op in ('div', 'mod'):
        quotient = abs(x) // abs(y)
        if (x < 0) != (y < 0): quotient = -quotient
        result = quotient if op == 'div' else x - quotient * y
    elif op == 'and': result = a & b
    elif op == 'or': result = a | b
    elif op == 'xor': result = a ^ b
    elif op == 'shl': result = a << (b & 31)
    else: result = a >> (b & 31)
    expression = f'({left} {op} {right})'
    if rng.randrange(7) == 0:
        expression = f'(not {expression})'; result = ~result
    return expression, result & MASK


def main(seed, count):
    root = Path(__file__).resolve().parents[1]
    output = root / f'build/audit-numeric/seed-{seed}-n-{count}'
    output.mkdir(parents=True, exist_ok=True)
    compiler = root / 'build/bin/PasToSPIRV.exe'
    validator = shutil.which('spirv-val')
    if not validator: raise RuntimeError('spirv-val is required for this audit')
    rng = random.Random(seed)
    expressions, expected = [], []
    for i in range(count):
        expression, value = generate(rng, bool(i & 1), rng.randrange(2, 5))
        expressions.append(expression); expected.append(value)
    prefix = 'var [Binding(0,0),WriteOnly] OutputData: array of Cardinal; procedure Main; begin if GlobalInvocationID.X = 0 then begin\n'
    body = '\n'.join(f'OutputData[{i}] := Cardinal({e});' for i, e in enumerate(expressions))
    (output / 'runtime.pas').write_text(prefix + body + '\nend; end;', encoding='utf-8')
    declarations = 'const\n' + '\n'.join(f'C{i} = {e};' for i, e in enumerate(expressions))
    const_body = '\n'.join(f'OutputData[{i}] := Cardinal(C{i});' for i in range(count))
    (output / 'constants.pas').write_text(declarations + '\n' + prefix + const_body + '\nend; end;', encoding='utf-8')
    golden = struct.pack(f'<{count}I', *expected)
    (output / 'expected.bin').write_bytes(golden)
    (output / 'cases.json').write_text(json.dumps({'seed': seed, 'count': count,
        'cases': [{'expression': expression, 'expected_u32': value} for expression, value in zip(expressions, expected)]}, indent=2), encoding='utf-8')
    with VulkanRuntime() as runtime:
        for name, option, source in (('O0', '-O0', 'runtime'), ('O1', '-O1', 'runtime'), ('const', '-O0', 'constants')):
            module = output / f'{name}.spv'
            completed = subprocess.run([str(compiler), str(output / f'{source}.pas'), option, '-o', str(module)],
                                       capture_output=True, text=True, encoding='utf-8')
            if completed.returncode: raise RuntimeError(completed.stderr)
            checked = subprocess.run([validator, '--target-env', 'vulkan1.0', str(module)], capture_output=True, text=True)
            if checked.returncode: raise RuntimeError(checked.stderr)
            actual = runtime.run(module, {'OutputData': bytes(len(golden))}, b'', 1)['OutputData']
            if actual != golden:
                words = struct.unpack(f'<{count}I', actual)
                for i, (value, wanted) in enumerate(zip(words, expected)):
                    if value != wanted:
                        raise AssertionError(f'{name} expression {i}: {expressions[i]} -> {value:08X}, expected {wanted:08X}')
        print(f'PASS: {count} independently evaluated arithmetic trees x 3 modes, seed={seed}; {runtime.dispatches} Vulkan dispatches.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=lambda x: int(x, 0), default=0xA0D17)
    parser.add_argument('--count', type=int, default=256)
    args = parser.parse_args()
    if not 1 <= args.count <= 4096: parser.error('count must be in 1..4096')
    main(args.seed, args.count)
