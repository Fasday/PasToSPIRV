"""Independent 1.1 audit: cast matrix, modular trees, refs and flow on real Vulkan."""
from __future__ import annotations

import argparse
from fractions import Fraction
import math
from pathlib import Path
import random
import struct
import subprocess

from vulkan_extended import ExtendedRuntime

MASK = (1 << 64)-1
TYPES = [('Byte', 8, False), ('Word', 16, False), ('Integer', 32, True),
         ('Cardinal', 32, False), ('Int64', 64, True), ('UInt64', 64, False),
         ('Single', 32, None), ('Double', 64, None)]


def binary(value, width, negative_zero=False):
    """Exact rational -> IEEE, nearest-even. No host float intermediate."""
    p, emin, emax, bias = (24, -126, 127, 127) if width == 32 else (53, -1022, 1023, 1023)
    negative = value < 0 or (value == 0 and negative_zero)
    value = abs(value)
    sign = int(negative) << (width-1)
    if not value:
        return sign
    n, d = value.numerator, value.denominator
    e = n.bit_length()-d.bit_length()
    if (n < d << e) if e >= 0 else (n << -e < d):
        e -= 1
    scale = max(e, emin)-(p-1)
    n <<= max(-scale, 0)
    d <<= max(scale, 0)
    q, r = divmod(n, d)
    if 2*r > d or (2*r == d and q & 1):
        q += 1
    if q == 1 << p:
        q >>= 1
        scale += 1
    if q < 1 << (p-1):
        return sign | q
    exponent = scale+p-1
    if exponent > emax:
        return sign | (((1 << (width-p))-1) << (p-1))
    return sign | ((exponent+bias) << (p-1)) | (q & ((1 << (p-1))-1))


def integer(raw, width, signed):
    raw &= (1 << width)-1
    return raw-(1 << width) if signed and raw & (1 << (width-1)) else raw


def compile_text(root, output, name, text, optimize):
    source = output / f'{name}.pas'
    source.write_text(text, encoding='utf-8')
    module = source.with_suffix('.spv')
    arguments = [str(root/'build/bin/PasToSPIRV.exe'), str(source), '-o', str(module)]
    if optimize:
        arguments.append('-O1')
    subprocess.run(arguments, check=True, capture_output=True)
    subprocess.run(['spirv-val', '--target-env', 'vulkan1.2', str(module)], check=True, capture_output=True)
    return module


def cast_probe(root, output, runtime, rng, count, optimize):
    inputs = [0, 1, MASK, 1 << 63, (1 << 63)-1, 0xFFFFFFFF, 0x80000000,
              0x8000008000000001, 0x1000001000000001]
    inputs += [rng.getrandbits(64) for _ in range(count-len(inputs))]
    doubles = [0.0, -0.0, -0.5, 0.5, -1.0, -1.5, 1.5, 127.5, 255.5, 256.0,
               65535.5, 65536.0, 2147483647.0, 2147483647.5, 2147483648.0,
               -2147483648.5, -2147483649.0, math.nextafter(2**63, 0),
               float(2**63), math.nextafter(2**64, 0), float(2**64),
               2**-1074, -2**-1074, 1e100, -1e100]
    doubles += [rng.uniform(-100000, 100000) for _ in range(count-len(doubles))]
    singles = [struct.unpack('<f', struct.pack('<f', x))[0] for x in
               [0.0, -0.0, -0.5, 0.5, -1.0, 255.5, 65535.5, 2147483648.0,
                -2147483648.0, 2**-149, -2**-149, 2**63, 2**64, 1e30]]
    singles += [struct.unpack('<f', struct.pack('<f', rng.uniform(-100000, 100000)))[0]
                for _ in range(count-len(singles))]
    declarations = ' '.join(f'A{n}: {n}; B{n}: {n};' for n, _, _ in TYPES)
    assignments = []
    for n, _, fp in TYPES:
        source = 'Input[I]' if fp is not None else ('Small[I]' if n == 'Single' else 'Reals[I]')
        assignments.append(f'A{n} := {n}({source});')
    expected = [0] * (count*64)
    body = []
    sentinel = 0xDEADBEEFDEADBEEF
    for src, (sn, sw, ss) in enumerate(TYPES):
        for dst, (dn, dw, ds) in enumerate(TYPES):
            offset = src*8+dst
            value = f'UInt64(B{dn})' if ds is not None else (
                f'UInt64(SingleToBits(B{dn}))' if dn == 'Single' else f'DoubleToBits(B{dn})')
            operation = f'B{dn} := {dn}(A{sn}); Output[O+{offset}] := {value};'
            if ss is None and ds is not None:
                suffix = 'd' if sn == 'Double' else ''
                if ds:
                    lower = -(1 << (dw-1))
                    low_guard = f'A{sn} >= {lower}.0{suffix}'
                    if sn == 'Double' and dw == 32:
                        low_guard = f'A{sn} > {lower-1}.0d'
                    upper = 1 << (dw-1)
                else:
                    low_guard, upper = f'A{sn} > -1.0{suffix}', 1 << dw
                operation = f'if ({low_guard}) and (A{sn} < {upper}.0{suffix}) then begin {operation} end else Output[O+{offset}] := $DEADBEEFDEADBEEF;'
            body.append(operation)
            for i in range(count):
                v = integer(inputs[i], sw, ss) if ss is not None else (singles[i] if sn == 'Single' else doubles[i])
                if ds is None:
                    expected[i*64+offset] = binary(Fraction(v), dw, v == 0 and math.copysign(1, v) < 0)
                else:
                    iv = int(v)
                    lower = -(1 << (dw-1)) if ds else 0
                    upper = (1 << (dw-1)) if ds else (1 << dw)
                    if ss is None and not lower <= iv < upper:
                        expected[i*64+offset] = sentinel
                    else:
                        expected[i*64+offset] = integer(iv, dw, ds) & MASK
    text = f'''var
      [Binding(0,0),ReadOnly] Input: array of UInt64;
      [Binding(0,1),ReadOnly] Small: array of Single;
      [Binding(0,2),ReadOnly] Reals: array of Double;
      [Binding(0,3),WriteOnly] Output: array of UInt64;
      [Vulkan12,StrictFloat,LocalSize(64,1,1)] procedure Main;
      var I: Cardinal; O: Cardinal; {declarations}
      begin I := GlobalInvocationID.X; if I < {count} then begin
      O := I*64; {' '.join(assignments)} {' '.join(body)} end; end;'''
    module = compile_text(root, output, 'casts', text, optimize)
    result = runtime.run(module, {'Input': struct.pack(f'<{count}Q', *inputs),
                                 'Small': struct.pack(f'<{count}f', *singles),
                                 'Reals': struct.pack(f'<{count}d', *doubles),
                                 'Output': bytes(count*64*8)}, b'', (count+63)//64)
    actual = struct.unpack(f'<{count*64}Q', result['Output'])
    for j, (a, b) in enumerate(zip(actual, expected)):
        assert a == b, f'cast {TYPES[(j%64)//8][0]} -> {TYPES[j%8][0]}, input {j//64}: {a:016x} != {b:016x}'
    return len(expected)


def integer_probe(root, output, runtime, rng, count, optimize):
    types = TYPES[:6]
    expressions, expected, counter = [], [[] for _ in range(count)], 0
    pairs = [(rng.getrandbits(64), rng.getrandbits(64) | 1) for _ in range(count)]
    pairs[:8] = [(0, 1), (MASK, 1), (1 << 63, 7), ((1 << 63)-1, MASK),
                 (0xFFFFFFFF, 31), (0x80000000, 63), (1, 64), (MASK, MASK)]
    for name, width, signed in types:
        for operation in ('+', '-', '*', 'div', 'mod', 'and', 'or', 'xor', 'shl', 'shr'):
            if operation in ('div', 'mod'):
                expr = f'(B{name} or {name}(1))'
                # A minimum signed integer / -1 is deliberately excluded as undefined.
                if signed:
                    expr = f'({expr} and {name}({(1 << (width-1))-1})) or {name}(1)'
                divisor = f'({expr})'
            else:
                divisor = 'C' if operation in ('shl', 'shr') else f'B{name}'
            expressions.append(f'Output[O+{counter}] := UInt64(A{name} {operation} {divisor});')
            for i, (a, b) in enumerate(pairs):
                av, bv = integer(a, width, signed), integer(b, width, signed)
                if operation in ('div', 'mod'):
                    bv = integer(b | 1, width, signed)
                    if signed:
                        bv = (bv & ((1 << (width-1))-1)) | 1
                    q = abs(av)//abs(bv) * (-1 if (av < 0) != (bv < 0) else 1)
                    value = q if operation == 'div' else av-q*bv
                elif operation == '+': value = av+bv
                elif operation == '-': value = av-bv
                elif operation == '*': value = av*bv
                elif operation == 'and': value = av & bv
                elif operation == 'or': value = av | bv
                elif operation == 'xor': value = av ^ bv
                elif operation == 'shl': value = av << (b & (width-1))
                else: value = (a & ((1 << width)-1)) >> (b & (width-1))
                expected[i].append(integer(value, width, signed) & MASK)
            counter += 1
    declarations = ' '.join(f'A{n}: {n}; B{n}: {n};' for n, _, _ in types)
    assignments = ' '.join(f'A{n} := {n}(Input[I*2]); B{n} := {n}(Input[I*2+1]);' for n, _, _ in types)
    text = f'''var [Binding(0,0),ReadOnly] Input: array of UInt64;
      [Binding(0,1),WriteOnly] Output: array of UInt64;
      [Vulkan12,LocalSize(64,1,1)] procedure Main;
      var I: Cardinal; O: Cardinal; C: UInt64; {declarations}
      begin I := GlobalInvocationID.X; if I < {count} then begin
        O := I*{counter}; C := Input[I*2+1]; {assignments} {' '.join(expressions)}
      end; end;'''
    module = compile_text(root, output, 'integers', text, optimize)
    result = runtime.run(module, {'Input': struct.pack(f'<{count*2}Q', *(x for p in pairs for x in p)),
                                 'Output': bytes(count*counter*8)}, b'', (count+63)//64)
    actual = struct.unpack(f'<{count*counter}Q', result['Output'])
    flat = [v for row in expected for v in row]
    for j, (a, b) in enumerate(zip(actual, flat)):
        assert a == b, f'integer row {j//counter} operation {j%counter}: {a:016x} != {b:016x}'
    return len(flat)


def reference_probe(root, output, runtime, rng, count, optimize):
    operations = []
    model = []
    for _ in range(96):
        a, b = rng.randrange(8), rng.randrange(8)
        v = rng.randrange(-100000, 100000)
        operations.append(f'Mix(D.Items[{a}], D.Items[{b}], Int64({v}));')
        model.append((a, b, v))
    expected = []
    for i in range(count):
        values = [((i+1)*123456789+j*977) & MASK for j in range(8)]
        for a, b, v in model:
            values[a] = (values[a]+v) & MASK
            values[b] = (values[b] ^ values[a]) & MASK
        expected.extend(values+[7])
    text = f'''type TItems = array[0..7] of Int64; TData = record Items: TItems; end;
      var [Binding(0,0),WriteOnly] Output: array of UInt64;
      procedure Mix(var A: Int64; var B: Int64; V: Int64);
      begin A := A+V; B := B xor A; end;
      function Init(out X: Integer): Integer; begin X := 4; Exit(3); end;
      procedure Late(var X: Integer; V: Integer); begin X := X+V; end;
      [Vulkan12,LocalSize(64,1,1)] procedure Main;
      var D: TData; I: Cardinal; J: Integer; X: Integer;
      begin I := GlobalInvocationID.X; if I < {count} then begin D := Default(TData);
        for J := 0 to 7 do D.Items[J] := Int64(I+1)*123456789 + Int64(J)*977;
        {' '.join(operations)}
        for J := 0 to 7 do Output[I*9+Cardinal(J)] := UInt64(D.Items[J]);
        Late(X, Init(X)); Output[I*9+8] := UInt64(X);
      end; end;'''
    module = compile_text(root, output, 'references', text, optimize)
    result = runtime.run(module, {'Output': bytes(count*9*8)}, b'', (count+63)//64)
    actual = struct.unpack(f'<{count*9}Q', result['Output'])
    assert actual == tuple(expected), 'Reference alias / argument evaluation order differs'
    return len(expected)


def loop_probe(root, output, runtime, count, optimize):
    text = f'''var [Binding(0,0),WriteOnly] Output: array of UInt64;
      [Vulkan12,LocalSize(64,1,1)] procedure Main;
      var I: Cardinal; O: Cardinal; S: Int64; U: UInt64; N: UInt64;
      begin I := GlobalInvocationID.X; if I < {count} then begin O := I*7;
        N := 0; for S := -9223372036854775808 to -9223372036854775807 do N := N+1;
        Output[O] := N;
        N := 0; for U := $FFFFFFFFFFFFFFFE to $FFFFFFFFFFFFFFFF do N := N+1;
        Output[O+1] := N;
        N := 0; for U := 0 downto 0 do N := N+1; Output[O+2] := N;
        N := 0; for S := 9223372036854775807 downto 9223372036854775806 do N := N+1;
        Output[O+3] := N;
        Output[O+4] := UInt64($FFFFFFFF + $100000000);
        Output[O+5] := $80000000 + $FFFFFFFFFFFFFFFF;
        Output[O+6] := $100000000 + $FFFFFFFFFFFFFFFF;
      end; end;'''
    module = compile_text(root, output, 'loop_edges', text, optimize)
    result = runtime.run(module, {'Output': bytes(count*7*8)}, b'', (count+63)//64)
    actual = struct.unpack(f'<{count*7}Q', result['Output'])
    assert actual == (2, 2, 1, 2, 0x1FFFFFFFF, 0x7FFFFFFF, 0xFFFFFFFF)*count, '64-bit loop or literal promotion differs'
    return len(actual)


def division_diagnostic(root, output, runtime, seed, optimize):
    # Deliberately not a pass/fail bit-equivalence criterion: native Vulkan FDiv
    # has a weaker accuracy contract than software correctly-rounded division.
    count = 4096
    rng = random.Random(seed)
    pairs = [(struct.unpack('<d', struct.pack('<Q', 0x3FF0000000000000 | rng.getrandbits(52)))[0],
              struct.unpack('<d', struct.pack('<Q', 0x3FF0000000000000 | rng.getrandbits(52)))[0])
             for _ in range(count)]
    text = f'''var [Binding(0,0),ReadOnly] Input: array of Double;
      [Binding(0,1),WriteOnly] Output: array of UInt64;
      [Vulkan12,StrictFloat,LocalSize(64,1,1)] procedure Main; var I: Cardinal;
      begin I := GlobalInvocationID.X; if I < {count} then
        Output[I] := DoubleToBits(Input[I*2] / Input[I*2+1]); end;'''
    module = compile_text(root, output, 'division_diagnostic', text, optimize)
    result = runtime.run(module, {'Input': struct.pack(f'<{count*2}d', *(x for p in pairs for x in p)),
                                 'Output': bytes(count*8)}, b'', count//64)
    actual = struct.unpack(f'<{count}Q', result['Output'])
    expected = [binary(Fraction(a)/Fraction(b), 64) for a, b in pairs]
    differences = sum(a != b for a, b in zip(actual, expected))
    largest = max(abs(a-b) for a, b in zip(actual, expected))
    print(f'INFO: native Double FDiv O{int(optimize)}, {differences}/{count} bit differences, '
          f'max {largest} ULP (diagnostic, not a bit-exactness guarantee).')


def main(count=256, seed=811031):
    root = Path(__file__).resolve().parents[1]
    output = root / 'build/audit11-gpu' / f'{seed}-{count}'
    output.mkdir(parents=True, exist_ok=True)
    total = 0
    with ExtendedRuntime() as runtime:
        for optimize in (False, True):
            rng = random.Random(seed)
            total += cast_probe(root, output, runtime, rng, count, optimize)
            total += integer_probe(root, output, runtime, rng, count, optimize)
            total += reference_probe(root, output, runtime, rng, count, optimize)
            total += loop_probe(root, output, runtime, count, optimize)
            division_diagnostic(root, output, runtime, seed, optimize)
        print(f'PASS: audit 1.1, {total} independent results, {runtime.dispatches} Vulkan dispatches, '
              f'O0/O1, count={count}, seed={seed}.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count', type=int, default=256)
    parser.add_argument('--seed', type=int, default=811031)
    args = parser.parse_args()
    if args.count < 32:
        parser.error('--count must be at least 32')
    main(args.count, args.seed)
