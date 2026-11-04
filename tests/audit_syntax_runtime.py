"""Audit of the 1.2/1.3 syntax: random programs executed on Vulkan and compared with an
independent Python model. Covers short-circuit and/or with side effects and {$B+},
if expressions, enumerations, sets and in, swizzle reads/writes, case ranges,
Inc/Dec/Include/Exclude, overloads, forward and nested routines that change captured
variables in the middle of expressions. Integer-only, so results are exact (O0/O1)."""
from __future__ import annotations

import argparse
from pathlib import Path
import random
import struct
import subprocess

from vulkan_smoke import VulkanRuntime

M32 = 0xFFFFFFFF
TRACE = 40
SLOTS = TRACE + 10
GROUP = 64
ENUM = {'eA': 0, 'eB': 1, 'eC': 5, 'eD': 6}
XYZW = 'XYZW'


def w32(v):
    v &= M32
    return v - (1 << 32) if v >> 31 else v


def u32(v):
    return v & M32


def trunc_div(a, b):
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def range_mask(lo, hi):
    low = (M32 << (u32(lo) & 31)) & M32
    high = M32 >> (u32(31 - u32(hi)) & 31)
    return low & high


class Ctx:
    def __init__(self, x, y, z, w):
        self.vars = {'X': x, 'Y': y, 'Z': z}
        self.M = u32(w) & 7
        self.S = (u32(w) >> 3) & 127
        self.V = [x, y, z, w32(x ^ y)]
        self.T = 0
        self.trace = []

    def note(self, n):
        if self.T < TRACE:
            self.trace.append(w32(n))
        self.T += 1


PRELUDE = '''type
  TMode = (eA, eB, eC = 5, eD);
  TModes = set of TMode;

var
  [Binding(0,0),ReadOnly] Input: array of Integer;
  [Binding(0,1),WriteOnly] Output: array of Integer;

function Twice(A: Integer): Integer; forward;

function Pick(A: Integer): Integer; overload;
begin
  Result := A * 3 + 1;
end;

function Pick(A: Cardinal): Integer; overload;
begin
  Result := Integer(A shr 1);
end;

function Pick(A: TMode): Integer; overload;
begin
  Result := Ord(A) * 100 + 7;
end;

function Pick(A, B: Integer): Integer; overload;
begin
  Result := Twice(A) - B;
end;

function Twice(A: Integer): Integer;
begin
  Result := A * 2;
end;

[LocalSize(64,1,1)]
procedure Main;
var
  X, Y, Z, T, Base: Integer;
  M: TMode;
  S: TModes;
  V: Integer4;

  procedure Note(N: Integer);
  begin
    if T < %(trace)d then Output[Base + T] := N;
    Inc(T);
  end;

  function Tap(K, N: Integer): Integer;
  begin
    Note(K);
    Result := N;
  end;

  function TapB(K: Integer; B: Boolean): Boolean;
  begin
    Note(K);
    Result := B;
  end;

  function TapS(K: Integer; A: TModes): TModes;
  begin
    Note(K);
    Result := A;
  end;

  function BumpX(N: Integer): Integer;
  begin
    X := X + N;
    Result := N;
  end;

begin
  Base := Integer(GlobalInvocationID.X) * %(slots)d;
  X := Input[GlobalInvocationID.X * 4];
  Y := Input[GlobalInvocationID.X * 4 + 1];
  Z := Input[GlobalInvocationID.X * 4 + 2];
  M := TMode(Cardinal(Input[GlobalInvocationID.X * 4 + 3]) and 7);
  S := TModes((Cardinal(Input[GlobalInvocationID.X * 4 + 3]) shr 3) and 127);
  V := Integer4(X, Y, Z, X xor Y);
  T := 0;
'''

EPILOGUE = '''  Output[Base + %(t)d] := X;
  Output[Base + %(t)d + 1] := Y;
  Output[Base + %(t)d + 2] := Z;
  Output[Base + %(t)d + 3] := Ord(M);
  Output[Base + %(t)d + 4] := Integer(Cardinal(S));
  Output[Base + %(t)d + 5] := V.X;
  Output[Base + %(t)d + 6] := V.Y;
  Output[Base + %(t)d + 7] := V.Z;
  Output[Base + %(t)d + 8] := V.W;
  Output[Base + %(t)d + 9] := T;
end;
'''


class Gen:
    def __init__(self, rng):
        self.r = rng
        self.complete = False

    # ---- integers -------------------------------------------------------
    def ints(self, d):
        r = self.r
        kinds = ['var', 'var', 'const', 'comp']
        if d > 0:
            kinds += ['bin', 'bin', 'bin', 'ordb', 'orde', 'cond', 'tap', 'bump', 'sqr', 'succ',
                      'pick', 'swz', 'card']
        k = r.choice(kinds)
        if k == 'var':
            n = r.choice('XYZ')
            return n, lambda c: c.vars[n]
        if k == 'const':
            v = r.choice([0, 1, 2, 7, 100, 12345, 2147483647, -3, -2147483647])
            return (f'({v})' if v < 0 else str(v)), lambda c: v
        if k == 'comp':
            i = r.randrange(4)
            return f'V.{XYZW[i]}', lambda c: c.V[i]
        if k == 'swz':
            letters = r.choice(['XYZW', 'RGBA'])
            sw = ''.join(r.choice(range(4)).__str__() for _ in range(r.randrange(2, 5)))
            idx = [int(ch) for ch in sw]
            j = r.randrange(len(idx))
            text = 'V.' + ''.join(letters[i] for i in idx) + '.' + letters[j]
            return text, lambda c: c.V[idx[j]]
        if k == 'bin':
            return self.int_binary(d)
        if k == 'ordb':
            bt, bf = self.bools(d - 1)
            return f'Ord({bt})', lambda c: int(bf(c))
        if k == 'orde':
            et, ef = self.enums(d - 1)
            return f'Ord({et})', lambda c: w32(ef(c))
        if k == 'cond':
            bt, bf = self.bools(d - 1)
            at, af = self.ints(d - 1)
            ct, cf = self.ints(d - 1)
            return f'(if {bt} then {at} else {ct})', lambda c: af(c) if bf(c) else cf(c)
        if k == 'tap':
            key = r.randrange(1, 100)
            at, af = self.ints(d - 1)

            def tap(c):
                v = af(c)
                c.note(key)
                return v
            return f'Tap({key}, {at})', tap
        if k == 'bump':
            at, af = self.ints(d - 1)

            def bump(c):
                n = af(c)
                c.vars['X'] = w32(c.vars['X'] + n)
                return n
            return f'BumpX({at})', bump
        if k == 'sqr':
            at, af = self.ints(d - 1)
            return f'Sqr({at})', lambda c: _sqr(af, c)
        if k == 'succ':
            at, af = self.ints(d - 1)
            if r.random() < 0.5:
                return f'Succ({at})', lambda c: w32(af(c) + 1)
            return f'Pred({at})', lambda c: w32(af(c) - 1)
        if k == 'pick':
            v = r.randrange(4)
            if v == 0:
                at, af = self.ints(d - 1)
                return f'Pick({at})', lambda c: w32(af(c) * 3 + 1)
            if v == 1:
                at, af = self.ints(d - 1)
                return f'Pick(Cardinal({at}))', lambda c: w32(u32(af(c)) >> 1)
            if v == 2:
                et, ef = self.enums(d - 1)
                return f'Pick({et})', lambda c: w32(ef(c) * 100 + 7)
            at, af = self.ints(d - 1)
            bt, bf = self.ints(d - 1)

            def pick2(c):
                a = af(c)
                b = bf(c)
                return w32(w32(a * 2) - b)
            return f'Pick({at}, {bt})', pick2
        st, sf = self.sets(d - 1, allow_empty=False)
        return f'Integer(Cardinal({st}))', lambda c: w32(sf(c))

    def int_binary(self, d):
        r = self.r
        op = r.choice(['+', '-', '*', 'xor', 'and', 'or', 'shr', 'shl', 'div', 'mod'])
        at, af = self.ints(d - 1)
        if op in ('*', 'shr', 'shl', 'div', 'mod'):
            k = r.choice({'*': [3, -7, 65537], 'shr': [0, 1, 5, 31, 32, 33], 'shl': [0, 1, 5, 31, 32, 33],
                          'div': [2, 3, 7, -3, -7], 'mod': [2, 3, 7, -3, -7]}[op])
            kt = f'({k})' if k < 0 else str(k)
            text = f'({at} {op} {kt})'
            if op == '*':
                return text, lambda c: w32(af(c) * k)
            if op == 'shr':
                return text, lambda c: w32(u32(af(c)) >> (k & 31))
            if op == 'shl':
                return text, lambda c: w32(af(c) << (k & 31))
            if op == 'div':
                return text, lambda c: w32(trunc_div(af(c), k))

            def mod(c):
                a = af(c)
                return w32(a - k * trunc_div(a, k))
            return text, mod
        bt, bf = self.ints(d - 1)

        def binary(c):
            a = af(c)
            b = bf(c)
            if op == '+':
                return w32(a + b)
            if op == '-':
                return w32(a - b)
            if op == 'xor':
                return w32(u32(a) ^ u32(b))
            if op == 'and':
                return w32(u32(a) & u32(b))
            return w32(u32(a) | u32(b))
        return f'({at} {op} {bt})', binary

    # ---- Booleans -------------------------------------------------------
    def bools(self, d):
        r = self.r
        kinds = ['const', 'cmp']
        if d > 0:
            kinds += ['cmp', 'ecmp', 'andor', 'andor', 'andor', 'not', 'inint', 'inset', 'inenum',
                      'setcmp', 'odd', 'tapb', 'cond']
        k = r.choice(kinds)
        if k == 'const':
            v = r.random() < 0.5
            return ('True' if v else 'False'), lambda c: v
        if k == 'cmp':
            op = r.choice(['<', '<=', '=', '<>', '>', '>='])
            at, af = self.ints(d - 1)
            bt, bf = self.ints(d - 1)
            return f'({at} {op} {bt})', _cmp(op, af, bf, False)
        if k == 'ecmp':
            op = r.choice(['<', '<=', '=', '<>', '>', '>='])
            at, af = self.enums(d - 1)
            bt, bf = self.enums(d - 1)
            return f'({at} {op} {bt})', _cmp(op, af, bf, True)
        if k == 'andor':
            op = r.choice(['and', 'or'])
            at, af = self.bools(d - 1)
            bt, bf = self.bools(d - 1)
            complete = self.complete

            def andor(c):
                a = af(c)
                if complete:
                    b = bf(c)
                    return (a and b) if op == 'and' else (a or b)
                if op == 'and':
                    return a and bf(c)
                return a or bf(c)
            return f'({at} {op} {bt})', andor
        if k == 'not':
            at, af = self.bools(d - 1)
            return f'(not {at})', lambda c: not af(c)
        if k == 'inint':
            at, af = self.ints(d - 1)
            items = [self.int_item(d - 1) for _ in range(r.randrange(0, 4))]
            neg = r.random() < 0.3

            # X once, then every item left to right (no short-circuit).
            def inint(c):
                v = af(c)
                hit = False
                for kind, f1, f2, _ in items:
                    if kind == 'range':
                        lo = f1(c)
                        hi = f2(c)
                        hit = (lo <= v <= hi) or hit
                    else:
                        one = f1(c)
                        hit = (v == one) or hit
                return not hit if neg else hit
            text = ', '.join(it[3] for it in items)
            return f'({at} {"not in" if neg else "in"} [{text}])', inint
        if k == 'inset':
            et, ef = self.enums(d - 1)
            st, sf = self.sets(d - 1, allow_empty=False)
            neg = r.random() < 0.3

            def inset(c):
                e = ef(c)
                s = sf(c)
                hit = (s >> (u32(e) & 31)) & 1 == 1
                return not hit if neg else hit
            # Parenthesized: a set value (bit test), not a constructor list (comparisons).
            return f'({et} {"not in" if neg else "in"} ({st}))', inset
        if k == 'inenum':
            et, ef = self.enums(d - 1)
            items = [self.enum_item(d - 1) for _ in range(r.randrange(1, 4))]

            def inenum(c):
                v = ef(c)
                hit = False
                for kind, f1, f2, _ in items:
                    if kind == 'range':
                        lo = f1(c)
                        hi = f2(c)
                        hit = (lo <= v <= hi) or hit
                    else:
                        one = f1(c)
                        hit = (v == one) or hit
                return hit
            return f'({et} in [{", ".join(it[3] for it in items)}])', inenum
        if k == 'setcmp':
            op = r.choice(['=', '<>', '<=', '>='])
            at, af = self.sets(d - 1, allow_empty=True)
            bt, bf = self.sets(d - 1, allow_empty=at != '[]')

            def setcmp(c):
                a = af(c)
                b = bf(c)
                if op == '=':
                    return a == b
                if op == '<>':
                    return a != b
                if op == '<=':
                    return a & ~b & M32 == 0
                return b & ~a & M32 == 0
            return f'({at} {op} {bt})', setcmp
        if k == 'odd':
            at, af = self.ints(d - 1)
            return f'Odd({at})', lambda c: af(c) & 1 == 1
        if k == 'tapb':
            key = r.randrange(100, 200)
            bt, bf = self.bools(d - 1)

            def tapb(c):
                v = bf(c)
                c.note(key)
                return v
            return f'TapB({key}, {bt})', tapb
        bt, bf = self.bools(d - 1)
        at, af = self.bools(d - 1)
        ct, cf = self.bools(d - 1)
        return f'(if {bt} then {at} else {ct})', lambda c: af(c) if bf(c) else cf(c)

    def int_item(self, d):
        if self.r.random() < 0.4:
            lt, lf = self.ints(d)
            ht, hf = self.ints(d)
            return ('range', lf, hf, f'{lt}..{ht}')
        t, f = self.ints(d)
        return ('one', f, None, t)

    def enum_item(self, d):
        if self.r.random() < 0.4:
            lt, lf = self.enums(d)
            ht, hf = self.enums(d)
            return ('range', lf, hf, f'{lt}..{ht}')
        t, f = self.enums(d)
        return ('one', f, None, t)

    # ---- enumerations ---------------------------------------------------
    def enums(self, d):
        r = self.r
        kinds = ['var', 'const', 'lowhigh']
        if d > 0:
            kinds += ['succ', 'cond', 'cast']
        k = r.choice(kinds)
        if k == 'var':
            return 'M', lambda c: c.M
        if k == 'const':
            name = r.choice(list(ENUM))
            v = ENUM[name]
            return (f'TMode.{name}' if r.random() < 0.3 else name), lambda c: v
        if k == 'lowhigh':
            return r.choice([('Low(TMode)', lambda c: 0), ('High(TMode)', lambda c: 6), ('High(M)', lambda c: 6)])
        if k == 'succ':
            et, ef = self.enums(d - 1)
            if r.random() < 0.5:
                return f'Succ({et})', lambda c: u32(ef(c) + 1)
            return f'Pred({et})', lambda c: u32(ef(c) - 1)
        if k == 'cond':
            bt, bf = self.bools(d - 1)
            at, af = self.enums(d - 1)
            ct, cf = self.enums(d - 1)
            return f'(if {bt} then {at} else {ct})', lambda c: af(c) if bf(c) else cf(c)
        at, af = self.ints(d - 1)
        return f'TMode({at} and 7)', lambda c: u32(af(c)) & 7

    # ---- sets -----------------------------------------------------------
    def sets(self, d, allow_empty):
        r = self.r
        kinds = ['var', 'ctor']
        if d > 0:
            kinds += ['bin', 'bin', 'tap', 'cond', 'cast']
        if allow_empty and r.random() < 0.15:
            return '[]', lambda c: 0
        k = r.choice(kinds)
        if k == 'var':
            return 'S', lambda c: c.S
        if k == 'ctor':
            items = [self.enum_item(max(d - 1, 0)) for _ in range(r.randrange(1, 4))]

            def ctor(c):
                bits = 0
                for kind, f1, f2, _ in items:
                    if kind == 'range':
                        lo = f1(c)
                        hi = f2(c)
                        bits |= range_mask(lo, hi)
                    else:
                        bits |= 1 << (u32(f1(c)) & 31)
                return bits
            return '[' + ', '.join(it[3] for it in items) + ']', ctor
        if k == 'bin':
            op = r.choice(['+', '*', '-'])
            at, af = self.sets(d - 1, allow_empty=True)
            bt, bf = self.sets(d - 1, allow_empty=at != '[]')

            def setbin(c):
                a = af(c)
                b = bf(c)
                if op == '+':
                    return a | b
                if op == '*':
                    return a & b
                return a & ~b & M32
            return f'({at} {op} {bt})', setbin
        if k == 'tap':
            key = r.randrange(200, 300)
            st, sf = self.sets(d - 1, allow_empty=True)

            def taps(c):
                v = sf(c)
                c.note(key)
                return v
            return f'TapS({key}, {st})', taps
        if k == 'cond':
            bt, bf = self.bools(d - 1)
            at, af = self.sets(d - 1, allow_empty=True)
            ct, cf = self.sets(d - 1, allow_empty=at != '[]')
            return f'(if {bt} then {at} else {ct})', lambda c: af(c) if bf(c) else cf(c)
        at, af = self.ints(d - 1)
        return f'TModes(Cardinal({at}) and 127)', lambda c: u32(af(c)) & 127

    # ---- statements -----------------------------------------------------
    def stmt(self, d):
        r = self.r
        kinds = ['assign', 'assign', 'assignm', 'assigns', 'note', 'note', 'inc', 'incm', 'incv', 'incl',
                 'vec', 'swzw', 'comp']
        if d > 0:
            kinds += ['if', 'case', 'casee', 'fore', 'block']
            if not self.complete:
                kinds.append('complete')
        k = r.choice(kinds)
        e = 3
        if k == 'assign':
            n = r.choice('XYZ')
            t, f = self.ints(e)

            def assign(c):
                c.vars[n] = f(c)
            return f'{n} := {t}', assign
        if k == 'assignm':
            t, f = self.enums(e)

            def assignm(c):
                c.M = f(c)
            return f'M := {t}', assignm
        if k == 'assigns':
            t, f = self.sets(e, allow_empty=True)

            def assigns(c):
                c.S = f(c)
            return f'S := {t}', assigns
        if k == 'note':
            t, f = self.ints(e)
            return f'Note({t})', lambda c: c.note(f(c))
        if k == 'inc':
            n = r.choice('XYZ')
            word = r.choice(['Inc', 'Dec'])
            sign = 1 if word == 'Inc' else -1
            if r.random() < 0.3:
                def inc1(c):
                    c.vars[n] = w32(c.vars[n] + sign)
                return f'{word}({n})', inc1
            t, f = self.ints(e)

            def incn(c):
                old = c.vars[n]
                amount = f(c)
                c.vars[n] = w32(old + sign * amount)
            return f'{word}({n}, {t})', incn
        if k == 'incm':
            word = r.choice(['Inc', 'Dec'])
            step = r.choice([1, 2])
            sign = 1 if word == 'Inc' else -1

            def incm(c):
                c.M = u32(c.M + sign * step)
            return (f'{word}(M)' if step == 1 else f'{word}(M, {step})'), incm
        if k == 'incv':
            i = r.randrange(4)
            t, f = self.ints(e)

            def incv(c):
                old = c.V[i]
                c.V[i] = w32(old + f(c))
            return f'Inc(V.{XYZW[i]}, {t})', incv
        if k == 'incl':
            word = r.choice(['Include', 'Exclude'])
            t, f = self.enums(e)

            def incl(c):
                old = c.S
                bit = 1 << (u32(f(c)) & 31)
                c.S = old | bit if word == 'Include' else old & ~bit & M32
            return f'{word}(S, {t})', incl
        if k == 'vec':
            parts = [self.ints(e - 1) for _ in range(4)]

            def vec(c):
                values = [f(c) for _, f in parts]
                c.V = values
            return 'V := Integer4(' + ', '.join(t for t, _ in parts) + ')', vec
        if k == 'swzw':
            count = r.randrange(2, 5)
            idx = r.sample(range(4), count)
            letters = r.choice(['XYZW', 'RGBA'])
            parts = [self.ints(e - 1) for _ in range(count)]

            def swzw(c):
                values = [f(c) for _, f in parts]
                for j, i in enumerate(idx):
                    c.V[i] = values[j]
            return (f'V.{"".join(letters[i] for i in idx)} := Integer{count}(' +
                    ', '.join(t for t, _ in parts) + ')'), swzw
        if k == 'comp':
            i = r.randrange(4)
            t, f = self.ints(e)

            def comp(c):
                c.V[i] = f(c)
            return f'V.{XYZW[i]} := {t}', comp
        if k == 'if':
            bt, bf = self.bools(e)
            a = self.block(d - 1)
            b = self.block(d - 1)

            def ifs(c):
                if bf(c):
                    a[1](c)
                else:
                    b[1](c)
            return f'if {bt} then {a[0]} else {b[0]}', ifs
        if k == 'case':
            t, f = self.ints(e)
            cuts = sorted(r.sample(range(1, 16), 3))
            arms = [(0, cuts[0] - 1), (cuts[0], cuts[1] - 1), (cuts[1], cuts[2] - 1)]
            blocks = [self.block(d - 1) for _ in range(4)]
            labels = []
            for lo, hi in arms:
                labels.append(f'{lo}..{hi}' if lo != hi else f'{lo}')

            def case(c):
                v = f(c) & 15
                for (lo, hi), blk in zip(arms, blocks):
                    if lo <= v <= hi:
                        blk[1](c)
                        return
                blocks[3][1](c)
            text = f'case ({t}) and 15 of ' + '; '.join(
                f'{lab}: {blk[0]}' for lab, blk in zip(labels, blocks)) + f'; else {blocks[3][0]}; end'
            return text, case
        if k == 'casee':
            t, f = self.enums(e)
            blocks = [self.block(d - 1) for _ in range(3)]

            def casee(c):
                v = f(c)
                if v == 0:
                    blocks[0][1](c)
                elif 1 <= v <= 5:
                    blocks[1][1](c)
                else:
                    blocks[2][1](c)
            return (f'case {t} of eA: {blocks[0][0]}; eB..eC: {blocks[1][0]}; else {blocks[2][0]}; end'), casee
        if k == 'fore':
            t, f = self.enums(e - 1)

            def fore(c):
                limit = w32(f(c)) & 7
                for q in range(0, limit + 1):
                    c.note(q)
            return f'for var Q := eA to TMode(Ord({t}) and 7) do Note(Ord(Q))', fore
        if k == 'complete':
            self.complete = True
            blk = self.block(d - 1)
            self.complete = False
            return '{$B+} ' + blk[0] + ' {$B-}', blk[1]
        return self.block(d - 1)

    def block(self, d):
        items = [self.stmt(d) for _ in range(self.r.randrange(1, 4))]

        def run(c):
            for _, f in items:
                f(c)
        return 'begin ' + '; '.join(t for t, _ in items) + '; end', run


def _sqr(af, c):
    v = af(c)
    return w32(v * v)


def _cmp(op, af, bf, unsigned):
    def cmp(c):
        a = af(c)
        b = bf(c)
        return {'<': a < b, '<=': a <= b, '=': a == b, '<>': a != b, '>': a > b, '>=': a >= b}[op]
    return cmp


def program(rng):
    gen = Gen(rng)
    statements = [gen.stmt(2) for _ in range(rng.randrange(6, 14))]
    text = PRELUDE % {'trace': TRACE, 'slots': SLOTS}
    text += ''.join(f'  {t};\n' for t, _ in statements)
    text += EPILOGUE % {'t': TRACE}

    def model(x, y, z, w):
        c = Ctx(x, y, z, w)
        for _, f in statements:
            f(c)
        out = c.trace + [0] * (TRACE - len(c.trace))
        out += [c.vars['X'], c.vars['Y'], c.vars['Z'], w32(c.M), w32(c.S)] + c.V + [w32(c.T)]
        return out
    return text, model


def main(programs, seed):
    root = Path(__file__).resolve().parents[1]
    output = root / 'build/audit-syntax-runtime' / f'{seed}-{programs}'
    output.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    edges = [0, 1, -1, 2147483647, -2147483648, 7, -7, 65536]
    compared = rejected = 0
    failures = []
    with VulkanRuntime() as runtime:
        for index in range(programs):
            text, model = program(rng)
            inputs = []
            for k in range(GROUP):
                inputs += [rng.choice(edges) if rng.random() < 0.3 else w32(rng.getrandbits(32))
                           for _ in range(3)] + [w32(rng.getrandbits(32))]
            source = output / f'program{index}.pas'
            source.write_text(text, encoding='utf-8')
            expected = []
            for k in range(GROUP):
                expected += model(*inputs[k * 4:k * 4 + 4])
            for optimize in (False, True):
                spv = output / f'program{index}_O{int(optimize)}.spv'
                args = [str(root / 'build/bin/PasToSPIRV.exe'), 'compile', str(source), '-o', str(spv)]
                if optimize:
                    args.append('-O1')
                result = subprocess.run(args, capture_output=True, text=True, encoding='utf-8')
                if result.returncode:
                    rejected += 1
                    failures.append(f'program{index}: compile error {result.stderr.strip()[-300:]}')
                    break
                valid = subprocess.run(['spirv-val', '--target-env', 'vulkan1.0', str(spv)],
                                       capture_output=True, text=True)
                if valid.returncode:
                    failures.append(f'program{index} O{int(optimize)}: invalid SPIR-V {valid.stdout}{valid.stderr}')
                    break
                got = runtime.run(spv, {'Input': struct.pack(f'<{GROUP * 4}i', *inputs),
                                        'Output': bytes(GROUP * SLOTS * 4)}, b'', 1)['Output']
                actual = list(struct.unpack(f'<{GROUP * SLOTS}i', got))
                compared += GROUP * SLOTS
                if actual != expected:
                    for k in range(GROUP):
                        a = actual[k * SLOTS:(k + 1) * SLOTS]
                        e = expected[k * SLOTS:(k + 1) * SLOTS]
                        if a != e:
                            slot = next(i for i in range(SLOTS) if a[i] != e[i])
                            failures.append(f'program{index} O{int(optimize)} invocation {k} slot {slot}: '
                                            f'GPU {a[slot]}, model {e[slot]} (inputs {inputs[k * 4:k * 4 + 4]})')
                            break
    if failures:
        for line in failures[:20]:
            print(line)
        raise SystemExit(f'FAIL: {len(failures)} failing program runs ({rejected} compile rejections)')
    print(f'PASS: {programs} random 1.2/1.3 programs x {GROUP} invocations x O0/O1, '
          f'{compared} values compared with the model, seed={seed}.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--programs', type=int, default=40)
    parser.add_argument('--seed', type=int, default=130401)
    args = parser.parse_args()
    main(args.programs, args.seed)
