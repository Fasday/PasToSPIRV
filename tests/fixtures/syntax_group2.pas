// Language 1.3 syntax (enumerations, sets, if expressions, swizzles, multi-
// dimensional arrays, record/vector typed constants, forward, overload, nested
// routines), checked on the GPU against fixed expected values
// (tests/vulkan_smoke.py). Default Vulkan 1.0 profile.
type
  TMode = (mNone, mAdd, mSub = 5, mMul);
  TModes = set of TMode;
  TPoint = record
    X, Y: Integer;
  end;
  TGrid = array[0..2, 0..3] of Integer;

const
  Origin: TPoint = (X: 3; Y: 4);
  Offsets: array[0..1] of TPoint = ((X: 1; Y: 2), (X: 10; Y: 20));
  Weights: Single3 = (0.5, 0.25, 2);
  Ops = [mAdd, mMul];

var
  [Binding(0,0),ReadOnly] In: array of Integer;
  [Binding(0,1),ReadWrite] Hits: array of Integer;
  [Binding(0,2),WriteOnly] O: array of Integer;

function Touch(V: Integer): Integer;
begin
  Hits[GlobalInvocationID.X] := Hits[GlobalInvocationID.X] + 1;
  Result := V;
end;

function Twice(A: Integer): Integer; forward;

function Apply(M: TMode; A, B: Integer): Integer;
begin
  case M of
    mAdd: Result := A + B;
    TMode.mSub: Result := A - B;
    mMul: Result := A * B;
  else
    Result := Twice(A);
  end;
end;

function Twice(A: Integer): Integer;
begin
  Result := A * 2;
end;

function Pick(A: Integer): Integer; overload;
begin
  Result := A + 1000;
end;

function Pick(A: Single): Integer; overload;
begin
  Result := Integer(A * 10);
end;

function Pick(A, B: Integer): Integer; overload;
begin
  Result := A * 100 + B;
end;

[LocalSize(64,1,1)]
procedure Main;
var
  X, Base, Acc, Count: Integer;
  M, Step: TMode;
  S: TModes;
  G: TGrid;
  V: Single4;
  W, Pair: Single2;

  procedure AddAcc(N: Integer);
  begin
    Acc := Acc + N;
  end;

  function Scaled(N: Integer): Integer;
  begin
    Result := N * X;
  end;

begin
  X := In[GlobalInvocationID.X];
  Base := Integer(GlobalInvocationID.X) * 16;
  // Only the selected branch runs: Touch is called only when X > 4.
  O[Base] := if X > 4 then Touch(X) else -X;
  M := if X mod 2 = 0 then mAdd else mMul;
  O[Base + 1] := Apply(M, X, 3) + Apply(mNone, X, 0) * 100;
  O[Base + 2] := Ord(Succ(mSub)) * 100 + Ord(High(TMode)) * 10 + Ord(Pred(mAdd));
  S := Ops;
  if X mod 3 = 0 then Include(S, mSub);
  Exclude(S, mAdd);
  O[Base + 3] := Integer(Cardinal(S)) + Ord(mSub in S) * 1000 + Ord(mNone in S) * 10000;
  O[Base + 4] := Ord(X in [1, 3, 5..7]) + Ord(X not in [0..2]) * 10;
  G := Default(TGrid);
  for var I := 0 to 2 do
    for var J := 0 to 3 do
      G[I, J] := I * 10 + J;
  O[Base + 5] := G[2, 3] + G[1][2] * 100 + High(G) * 10000 + Length(G[0]) * 100000;
  V := Single4(X, 2, 3, 4);
  W := V.WX;
  V.YZ := W;
  O[Base + 6] := Integer(V.X + V.Y * 10 + V.Z * 100 + V.W * 1000 + W.Y * 10000);
  O[Base + 7] := Origin.X * 10 + Origin.Y + Offsets[X and 1].Y * 100 + Integer(Weights.Z * 1000);
  O[Base + 8] := Pick(X) + Pick(1.5) + Pick(X, 7);
  Acc := 0;
  AddAcc(X);
  AddAcc(Scaled(2));
  O[Base + 9] := Acc;
  O[Base + 10] := (if X > 2 then Offsets[1] else Origin).X;
  O[Base + 11] := Ord([mAdd] <= Ops) + Ord(Ops >= [mSub]) * 10 + Ord(S = [mMul]) * 100 +
    Ord(Ops - [mAdd] = [mMul]) * 1000;
  Count := 0;
  for var Q := Low(TMode) to High(TMode) do Inc(Count);
  O[Base + 12] := Count;
  Step := mNone;
  Inc(Step, 5);
  O[Base + 13] := Ord(Step);
  O[Base + 14] := Ord(M in [mAdd..mSub]);
  Pair := if X > 0 then Single2(1, 2) else Single2(3, 4);
  O[Base + 15] := Integer(Pair.X * 10 + Pair.Y);
end;
