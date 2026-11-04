// Vulkan12 parts of the language 1.3 syntax: var/out references to variables
// captured by nested routines (Private memory roots), overloads with var
// parameters and a forward-declared procedure (tests/vulkan_extended.py).
type
  TArr = array[0..3] of Integer;
  TPair = record
    A, B: Integer;
  end;

var
  [Binding(0,0),WriteOnly] Output: array of Integer;

procedure Swap(var A, B: Integer); overload;
var T: Integer;
begin
  T := A; A := B; B := T;
end;

procedure Swap(var A, B: Single); overload;
var T: Single;
begin
  T := A; A := B; B := T;
end;

procedure Bump(var V: Integer; N: Integer); forward;

// Field and swizzle writes through references whose root may be Private (captured).
procedure SetB(var P: TPair; V: Integer);
begin
  P.B := V;
end;

procedure SwapXY(var V: Integer4);
begin
  V.XY := V.YX;
  Inc(V.W, 5);
end;

procedure Twice(var V: Integer);
begin
  Bump(V, V);
end;

procedure Bump(var V: Integer; N: Integer);
begin
  V := V + N;
end;

[Vulkan12, LocalSize(64,1,1)]
procedure Main;
var
  A, B, Base: Integer;
  F, G: Single;
  Arr: TArr;
  Pr: TPair;
  Vec: Integer4;

  procedure Mix;
  begin
    Swap(A, B);
    Bump(Arr[A and 3], 100);
  end;

  procedure Fix;
  begin
    SetB(Pr, A + 1);
    SwapXY(Vec);
  end;

  function Total: Integer;
  begin
    Result := A * 10 + B + Arr[0] + Arr[1] + Arr[2] + Arr[3];
  end;

begin
  Base := Integer(GlobalInvocationID.X) * 6;
  A := Integer(GlobalInvocationID.X);
  B := 7;
  Arr := Default(TArr);
  Mix;
  Output[Base] := Total;
  F := 1.5;
  G := 2.5;
  Swap(F, G);
  Output[Base + 1] := Integer(F * 10 + G);
  Twice(A);
  Output[Base + 2] := A;
  Output[Base + 3] := Arr[B and 3];
  Pr := Default(TPair);
  Vec := Integer4(1, 2, 3, 4);
  Fix;
  Output[Base + 4] := Pr.B * 10 + Pr.A;
  Output[Base + 5] := Vec.X * 1000 + Vec.Y * 100 + Vec.Z * 10 + Vec.W;
end;
