"""Definite-assignment audit against an independent explicit-state interpreter."""
from __future__ import annotations

import argparse
from pathlib import Path
import random
import subprocess

NORMAL, BREAK, CONTINUE, RETURN, BAD = range(5)
NAMES = ['X', 'Y', 'C']


def generate(rng, depth, loop=False, counter=False):
    choices = ['assign', 'copy', 'read', 'out', 'use', 'late', 'return']
    if loop:
        choices += ['break', 'continue']
    if depth:
        choices += ['block', 'if', 'while', 'repeat', 'case']
        if not counter:
            choices.append('for')
    kind = rng.choice(choices)
    available = [0, 1] if counter else [0, 1, 2]
    if kind in ('assign', 'out', 'use', 'late'):
        return kind, rng.choice(available)
    if kind == 'read':
        return kind, rng.randrange(3)
    if kind == 'copy':
        return kind, rng.choice(available), rng.randrange(3)
    if kind in ('break', 'continue', 'return'):
        return kind,
    if kind == 'block':
        return kind, [generate(rng, depth-1, loop, counter) for _ in range(rng.randrange(2, 5))]
    if kind == 'if':
        return kind, generate(rng, depth-1, loop, counter), generate(rng, depth-1, loop, counter)
    if kind == 'case':
        return kind, [generate(rng, depth-1, loop, counter) for _ in range(3)]
    return kind, generate(rng, depth-1, True, counter or kind == 'for')


def execute(node, state):
    kind = node[0]
    if kind == 'assign' or kind == 'out' or kind == 'late':
        return {(state | (1 << node[1]), NORMAL)}
    if kind == 'read' or kind == 'use':
        return {(state, NORMAL if state & (1 << node[1]) else BAD)}
    if kind == 'copy':
        return {(state | (1 << node[1]), NORMAL)} if state & (1 << node[2]) else {(state, BAD)}
    if kind in ('break', 'continue', 'return'):
        return {(state, {'break': BREAK, 'continue': CONTINUE, 'return': RETURN}[kind])}
    if kind == 'block':
        paths = {(state, NORMAL)}
        for child in node[1]:
            paths = {out for s, status in paths for out in (
                execute(child, s) if status == NORMAL else {(s, status)})}
        return paths
    if kind == 'if':
        return execute(node[1], state) | execute(node[2], state)
    if kind == 'case':
        return set().union(*(execute(child, state) for child in node[1]))
    paths, pending, visited = set(), {state}, set()
    while pending:
        s = pending.pop()
        if s in visited:
            continue
        visited.add(s)
        if kind == 'while':
            paths.add((s, NORMAL))  # condition may be false before the first iteration
        if kind == 'for':
            paths.add((s & ~4, NORMAL))
            s |= 4
        for after, status in execute(node[1], s):
            if status == BAD or status == RETURN:
                paths.add((after, status))
            elif status == BREAK:
                paths.add((after & ~4 if kind == 'for' else after, NORMAL))
            else:
                if kind == 'repeat':
                    paths.add((after, NORMAL))  # until may be true after the body
                pending.add(after)
    return paths


def render(node):
    kind = node[0]
    if kind == 'assign': return f'{NAMES[node[1]]} := 1'
    if kind == 'copy': return f'{NAMES[node[1]]} := {NAMES[node[2]]}'
    if kind == 'read': return f'D[GlobalInvocationID.X] := {NAMES[node[1]]}'
    if kind == 'out': return f'SetValue({NAMES[node[1]]})'
    if kind == 'use': return f'UseValue({NAMES[node[1]]})'
    if kind == 'late': return f'LateValue({NAMES[node[1]]}, Init({NAMES[node[1]]}))'
    if kind in ('break', 'continue', 'return'):
        return {'break': 'Break', 'continue': 'Continue', 'return': 'Exit'}[kind]
    if kind == 'block': return 'begin ' + '; '.join(render(c) for c in node[1]) + '; end'
    if kind == 'if':
        return 'if GlobalInvocationID.X = 0 then ' + render(node[1]) + ' else ' + render(node[2])
    if kind == 'case':
        a, b, c = node[1]
        return f'case GlobalInvocationID.X of 0: {render(a)}; 1: {render(b)}; else {render(c)}; end'
    if kind == 'while': return 'while GlobalInvocationID.X = 0 do ' + render(node[1])
    if kind == 'for': return 'for C := 0 to Integer(GlobalInvocationID.X and 1) do ' + render(node[1])
    return 'repeat ' + render(node[1]) + '; until GlobalInvocationID.X = 0'


PREFIX = '''var [Binding(0,0),WriteOnly] D: array of Integer;
procedure SetValue(out P: Integer); begin P := 1; end;
procedure UseValue(var P: Integer); begin P := P+1; end;
function Init(out P: Integer): Integer; begin P := 4; Result := 3; end;
procedure LateValue(var P: Integer; V: Integer); begin P := P+V; end;
[Vulkan12] procedure Main; var X: Integer; Y: Integer; C: Integer;
'''


def main(count=300, seed=811033, validator='spirv-val'):
    root = Path(__file__).resolve().parents[1]
    output = root/'build/audit11-flow'/f'{seed}-{count}'
    output.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    success = 0
    for i in range(count):
        tree = ('block', [generate(rng, 3) for _ in range(rng.randrange(1, 5))] + [('return',)])
        safe = all(status != BAD for _, status in execute(tree, 0))
        source = output/f'flow{i}.pas'
        source.write_text(PREFIX+render(tree)+';', encoding='utf-8')
        module = source.with_suffix('.spv')
        for optimize in (False, True):
            args = [str(root/'build/bin/PasToSPIRV.exe'), str(source), '-o', str(module)]
            if optimize:
                args.append('-O1')
            result = subprocess.run(args, capture_output=True, text=True)
            expected = 0 if safe else 1
            assert result.returncode == expected, f'{source}, expected code {expected}, got {result.returncode}: {result.stderr}'
            if safe:
                subprocess.run([validator, '--target-env', 'vulkan1.2', str(module)], check=True, capture_output=True)
            else:
                assert 'uninitialized' in result.stderr, f'Unexpected rejection of {source}: {result.stderr}'
        success += int(safe)
    print(f'PASS: {count} explicit-state flow cases x O0/O1, {success} accepted, '
          f'{count-success} rejected, seed={seed}.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count', type=int, default=300)
    parser.add_argument('--seed', type=int, default=811033)
    parser.add_argument('--spirv-val', default='spirv-val')
    args = parser.parse_args()
    main(args.count, args.seed, args.spirv_val)
