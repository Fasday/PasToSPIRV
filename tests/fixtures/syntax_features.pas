// Language 1.2 syntax, checked on the GPU against fixed expected values
// (tests/vulkan_smoke.py). Default Vulkan 1.0 profile.
type
  TPair = record
    A, B: Integer;
  end;
  TArr = array[0..4] of Integer;

const
  Scale = 3;

var
  [Binding(0,0),ReadOnly] In: array of Integer;
  [Binding(0,1),ReadWrite] Hits: array of Integer;
  [Binding(0,2),WriteOnly] O: array of Integer;

function Touch(V: Boolean): Boolean;
begin
  Hits[GlobalInvocationID.X] := Hits[GlobalInvocationID.X] + 1;
  Result := V;
end;

function Twice: Integer;
begin
  Twice := 2; // assignment to the function name sets the result
end;

[LocalSize(64,1,1)]
procedure Main;
const
  Limit = 4;
var
  X, Y: Integer;
  P: TPair;
  A: TArr;
  Base: Cardinal;
begin
  Base := GlobalInvocationID.X * 12;
  X := In[GlobalInvocationID.X];
  P := Default(TPair);
  P.A := X;
  P.B := X * Scale;
  O[Base] := P.A + P.B;
  var Sum := 0;
  for var I := 0 to Limit do Inc(Sum, I);
  O[Base + 1] := Sum;
  A := Default(TArr);
  for var I := Low(A) to High(A) do A[I] := I * I;
  Inc(A[2]);
  Dec(A[3], 2);
  O[Base + 2] := A[2] + A[3] + Length(A);
  begin
    var Local: Integer := Sqr(X);
    const K = 10;
    O[Base + 3] := Local + K;
  end;
  case X of
    0..2: Y := 1;
    3, 5..7: Y := 2;
  else
    Y := 3;
  end;
  O[Base + 4] := Y;
  O[Base + 5] := Ord(Odd(X)) + Succ(X) * 10 + Pred(X) * 100;
  O[Base + 6] := SizeOf(TPair) + SizeOf(Single3);
  O[Base + 7] := Twice;
  // Short-circuit (default {$B-}): Touch runs only when X > 3.
  if (X > 3) and Touch(True) then O[Base + 8] := 1 else O[Base + 8] := 0;
  {$B+}
  // Complete evaluation: Touch always runs.
  if (X > 100) and Touch(False) then O[Base + 9] := 1 else O[Base + 9] := 0;
  {$B-}
  O[Base + 10] := Integer(Length(In));
  var R := 0;
  repeat
    var Step := 2;
    Inc(R, Step);
  until R >= 6;
  O[Base + 11] := R;
end;
