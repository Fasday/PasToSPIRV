var
  [Binding(0,0)] Counts: array of Integer;
  [Binding(0,1), WriteOnly] Target: array of Integer4;

function NextValue: Integer2;
begin
  var Value := Counts[0];
  Counts[0] := Value + 1;
  Result := Integer2(Value, Value + 10);
end;

[LocalSize(1,1,1)]
procedure Main;
begin
  Target[0] := Integer4(NextValue, NextValue);
  Target[1] := ArithmeticShiftRight(Integer4(-16, -8, -4, -1), 2);
  Target[2] := ArithmeticShiftRight(Integer4(-8, 4, -16, 32), Integer4(32, 33, -1, 31));
end;
