var
  [Binding(0, 0), ReadWrite]
  Data: array of Integer;

  [PushConstant]
  Params: record
    Count: Cardinal;
  end;

[LocalSize(64, 1, 1)]
procedure Main;
var
  Index: Cardinal;
  Value: Integer;
  Step: Integer;
begin
  Index := GlobalInvocationID.X;
  if Index < Params.Count then
  begin
    Value := Data[Index];
    Step := 0;
    while Step < 3 do
    begin
      if (Value and 1) = 0 then
        Value := Value shr 1
      else
        Value := Value * 3 + 1;
      Step := Step + 1;
    end;
    Data[Index] := Value;
  end;
end;
