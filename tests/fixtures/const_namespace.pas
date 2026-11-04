uses A, B;
const
  Total: Cardinal = A.N + B.N;
  Wrapped: Cardinal = $FFFFFFFF + 1;
  Half: Single = 1 / 2;
type TValues = array[0..Total - 1] of Cardinal;
var [Binding(0,0)] OutputData: array of Cardinal;
procedure Main;
var Values: TValues; First: A.TData; Second: B.TData;
begin
  if GlobalInvocationID.X = 0 then
  begin
    Values := Default(TValues);
    Values[0] := A.F(1); Values[1] := B.F(1);
    First := Default(A.TData); First.Value := Total;
    Second := Default(B.TData); Second.Value := Single2(2,3);
    OutputData[0] := Total;
    OutputData[1] := Values[0]; OutputData[2] := Values[1];
    OutputData[3] := First.Value; OutputData[4] := Cardinal(Second.Value.Y);
    OutputData[5] := Wrapped; OutputData[6] := Cardinal(Half * 100);
    OutputData[7] := Cardinal((-7 mod 3) + 9);
    OutputData[8] := Cardinal((-1 shr 1));
  end;
end;
