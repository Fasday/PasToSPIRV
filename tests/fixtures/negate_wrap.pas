// Integer negation and Abs must wrap (-Low(Integer) = Low(Integer)) and must not
// be optimized as if overflow were impossible. Inputs: I[0] = Low(Integer), I[1] = 7.
var
  [Binding(0,0),ReadOnly] I: array of Integer;
  [Binding(0,1),WriteOnly] O: array of Integer;

[LocalSize(1,1,1)]
procedure Main;
var
  A: Integer;
  S: Integer;
begin
  A := I[0];
  S := I[1];
  O[0] := (-A) div S;
  O[1] := Abs(A) div S;
  if (-A) < 0 then O[2] := 1 else O[2] := 0;
  if Abs(A) >= 0 then O[3] := 1 else O[3] := 0;
  O[4] := (-A) mod S;
  O[5] := (A * (-1)) div S;
end;
