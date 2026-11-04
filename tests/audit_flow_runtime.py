"""Re-audit: execute random structured programs on Vulkan and compare traces with an
independent Python interpreter (loops, break/continue, case, Exit, var aliases)."""
from __future__ import annotations

import argparse
from pathlib import Path
import random
import struct
import subprocess

from vulkan_extended import ExtendedRuntime

TRACE = 48
GROUP = 64


def w32(v):
    v &= 0xFFFFFFFF
    return v-(1 << 32) if v >> 31 else v


class Break_(Exception):
    pass


class Continue_(Exception):
    pass


class Exit_(Exception):
    pass


class Gen:
    def __init__(self, rng):
        self.rng = rng

    def expr(self, counters):
        names = ['X', 'Y'] + counters
        a, b = self.rng.choice(names), self.rng.choice(names)
        k = self.rng.randrange(1, 9)
        return self.rng.choice([f'{a} + {b}', f'{a} - {k}', f'{a} * {k} + {b}', f'{a} xor ({b} shl {k})',
                                f'{a} and {b}', f'{a} or {k}', f'(-{a}) + {k}'])

    def stmt(self, depth, loop, counters, nest=0):
        kinds = ['assign', 'assign', 'note', 'mix', 'pick']
        if loop:
            kinds += ['break', 'continue']
        if depth:
            kinds += ['if', 'case', 'for', 'while', 'repeat', 'block']
        kinds.append('exit')
        kind = self.rng.choice(kinds)
        if kind == 'assign':
            return ('assign', self.rng.choice('XY'), self.expr(counters))
        if kind == 'note':
            return ('note', self.rng.choice(['X', 'Y'] + counters))
        if kind == 'mix':
            return ('mix', self.rng.choice('XY'), self.rng.choice('XY'))
        if kind == 'pick':
            return ('pick', self.rng.choice('XY'), self.rng.choice('XY'))
        if kind in ('break', 'continue', 'exit'):
            return (kind, self.rng.randrange(8))
        if kind == 'block':
            return ('block', [self.stmt(depth-1, loop, counters, nest) for _ in range(self.rng.randrange(1, 4))])
        if kind == 'if':
            return ('if', self.rng.randrange(4), self.block(depth, loop, counters, nest), self.block(depth, loop, counters, nest))
        if kind == 'case':
            return ('case', [self.block(depth, loop, counters, nest) for _ in range(3)])
        level = nest
        inner = counters + [f'C{level}'] if kind == 'for' else counters
        body = self.block(depth, True, inner, nest+1)
        return (kind, level, self.rng.randrange(4), body)

    def block(self, depth, loop, counters, nest=0):
        return ('block', [self.stmt(depth-1, loop, counters, nest) for _ in range(self.rng.randrange(1, 4))])


def render(node):
    kind = node[0]
    if kind == 'assign':
        return f'{node[1]} := {node[2]}'
    if kind == 'note':
        return f'Note(T, {node[1]})'
    if kind == 'mix':
        return f'Mix({node[1]}, {node[2]})'
    if kind == 'pick':
        return f'{node[1]} := Pick({node[2]})'
    if kind in ('break', 'continue', 'exit'):
        word = {'break': 'Break', 'continue': 'Continue', 'exit': 'Exit'}[kind]
        return f'if (X and 7) = {node[1]} then {word}'
    if kind == 'block':
        return 'begin ' + '; '.join(render(c) for c in node[1]) + '; end'
    if kind == 'if':
        return f'if (Y and 3) = {node[1]} then {render(node[2])} else {render(node[3])}'
    if kind == 'case':
        a, b, c = node[1]
        return f'case X and 3 of 0: {render(a)}; 1, 2: {render(b)}; else {render(c)}; end'
    level, limit, body = node[1], node[2], node[3]
    if kind == 'for':
        return f'for C{level} := 0 to {limit} + (Y and 1) do {render(body)}'
    if kind == 'while':
        return f'begin L{level} := 0; while L{level} < {limit} + 1 do begin L{level} := L{level} + 1; {render(body)}; end; end'
    return f'begin L{level} := 0; repeat L{level} := L{level} + 1; {render(body)}; until L{level} >= {limit} + 1; end'


class Interp:
    def __init__(self, x, y):
        self.env = {'X': w32(x), 'Y': w32(y)}
        self.trace = []

    def ev(self, text):
        e = dict(self.env)
        # Same small grammar as Gen.expr, evaluated with Python ints, wrapped to 32 bits.
        py = text.replace('xor', '^').replace('and', '&').replace('or', '|').replace('shl', '<<')
        return w32(eval(py, {}, e))

    def note(self, value):
        if len(self.trace) < TRACE:
            self.trace.append(w32(value))

    def pick(self, v):
        sel = v & 3
        if sel == 0:
            return w32(v*3)
        if sel == 1:
            return w32(v+7)
        r = w32(v ^ 5)
        if v < 0:
            return r
        return w32(r+1)

    def run(self, node):
        kind = node[0]
        env = self.env
        if kind == 'assign':
            env[node[1]] = self.ev(node[2])
        elif kind == 'note':
            self.note(env[node[1]])
        elif kind == 'mix':
            a, b = node[1], node[2]
            env[a] = w32(env[a]+env[b])
            env[b] = w32(env[b] ^ w32(env[a] << 3))
        elif kind == 'pick':
            env[node[1]] = self.pick(env[node[2]])
        elif kind in ('break', 'continue', 'exit'):
            if env['X'] & 7 == node[1]:
                raise {'break': Break_, 'continue': Continue_, 'exit': Exit_}[kind]()
        elif kind == 'block':
            for child in node[1]:
                self.run(child)
        elif kind == 'if':
            self.run(node[2] if env['Y'] & 3 == node[1] else node[3])
        elif kind == 'case':
            sel = env['X'] & 3
            self.run(node[1][0] if sel == 0 else node[1][1] if sel in (1, 2) else node[1][2])
        else:
            level, limit, body = node[1], node[2], node[3]
            if kind == 'for':
                name = f'C{level}'
                for value in range(0, limit + (env['Y'] & 1) + 1):
                    env[name] = value
                    try:
                        self.run(body)
                    except Continue_:
                        pass
                    except Break_:
                        break
                env.pop(name, None)
            else:
                name = f'L{level}'
                env[name] = 0
                while True:
                    if kind == 'while' and not env[name] < limit+1:
                        break
                    env[name] += 1
                    try:
                        self.run(body)
                    except Continue_:
                        pass
                    except Break_:
                        break
                    if kind == 'repeat' and env[name] >= limit+1:
                        break


PREFIX = f'''var
  [Binding(0,0),ReadOnly] In: array of Integer;
  [Binding(0,1),WriteOnly] O: array of Integer;
procedure Note(var T: Integer; V: Integer);
begin
  if T < {TRACE} then begin O[GlobalInvocationID.X * {TRACE} + Cardinal(T)] := V; T := T + 1; end;
end;
procedure Mix(var A: Integer; var B: Integer);
begin A := A + B; B := B xor (A shl 3); end;
function Pick(V: Integer): Integer;
begin
  case V and 3 of
    0: Exit(V * 3);
    1: Result := V + 7;
  else begin Result := V xor 5; if V < 0 then Exit; Result := Result + 1; end;
  end;
end;
[Vulkan12,LocalSize({GROUP},1,1)]
procedure Main;
var X: Integer; Y: Integer; T: Integer;
  C0: Integer; C1: Integer; C2: Integer; C3: Integer; C4: Integer;
  L0: Integer; L1: Integer; L2: Integer; L3: Integer; L4: Integer;
begin
  X := In[GlobalInvocationID.X * 2]; Y := In[GlobalInvocationID.X * 2 + 1]; T := 0;
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--programs', type=int, default=40)
    parser.add_argument('--depth', type=int, default=4)
    parser.add_argument('--seed', type=int, default=940311)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = root/'build/audit-flow-runtime'/f'{args.seed}-{args.programs}'
    output.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    compared = 0
    with ExtendedRuntime() as runtime:
        for p in range(args.programs):
            gen = Gen(random.Random(args.seed*7919+p))
            program = ('block', [gen.stmt(args.depth, False, []) for _ in range(rng.randrange(2, 6))])
            source = PREFIX + '  ' + render(program) + ';\n  Note(T, X); Note(T, Y);\nend;\n'
            path = output/f'program{p}.pas'
            path.write_text(source, encoding='utf-8')
            inputs = [rng.choice([0, 1, -1, 5, 7, -(1 << 31), (1 << 31)-1, rng.getrandbits(32)])
                      for _ in range(2*GROUP)]
            inputs = [w32(v) for v in inputs]
            expected = []
            for i in range(GROUP):
                machine = Interp(inputs[2*i], inputs[2*i+1])
                try:
                    machine.run(program)
                    machine.note(machine.env['X'])
                    machine.note(machine.env['Y'])
                except Exit_:
                    pass
                expected += machine.trace + [0]*(TRACE-len(machine.trace))
            for optimize in (False, True):
                module = output/f'program{p}_O{int(optimize)}.spv'
                cmd = [str(root/'build/bin/PasToSPIRV.exe'), str(path), '-o', str(module)] + (['-O1'] if optimize else [])
                compiled = subprocess.run(cmd, capture_output=True, text=True)
                assert compiled.returncode == 0, f'{path}: {compiled.stderr}'
                subprocess.run(['spirv-val', '--target-env', 'vulkan1.2', str(module)], check=True, capture_output=True)
                result = runtime.run(module, {'In': struct.pack(f'<{2*GROUP}i', *inputs),
                                              'O': bytes(4*TRACE*GROUP)}, b'', 1)
                actual = list(struct.unpack(f'<{TRACE*GROUP}i', result['O']))
                for i in range(GROUP):
                    row = slice(i*TRACE, (i+1)*TRACE)
                    assert actual[row] == expected[row], (f'{path} O{int(optimize)} invocation {i} '
                                                          f'input {inputs[2*i]},{inputs[2*i+1]}\n'
                                                          f'got  {actual[row]}\nwant {expected[row]}')
                compared += TRACE*GROUP
    print(f'PASS: {args.programs} random programs x {GROUP} invocations x O0/O1, '
          f'{compared} trace values, seed={args.seed}.')


if __name__ == '__main__':
    main()
