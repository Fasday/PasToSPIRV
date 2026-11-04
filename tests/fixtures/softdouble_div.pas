// GPU check of lib/SoftDouble.pasm (tests/softdouble_gpu.py): every invocation
// divides one pair of binary64 bit patterns, through both SoftDivBits and the
// Double overload SoftDiv. Compile with -I lib.
uses SoftDouble;

var
  [Binding(0,0),ReadOnly] Pairs: array of UInt64;
  [Binding(0,1),WriteOnly] Quotients: array of UInt64;
  [Binding(0,2),WriteOnly] Values: array of Double;

[Vulkan12, LocalSize(64,1,1)]
procedure Main;
var
  I: Cardinal;
  A, B: UInt64;
begin
  I := GlobalInvocationID.X;
  if I >= Length(Quotients) then Exit;
  A := Pairs[2 * I];
  B := Pairs[2 * I + 1];
  Quotients[I] := SoftDivBits(A, B);
  Values[I] := SoftDiv(BitsToDouble(A), BitsToDouble(B));
end;
