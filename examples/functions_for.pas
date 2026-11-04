var
  [Binding(0, 0), ReadWrite]
  Data: array of Integer;

  [PushConstant]
  Params: record
    Count: Cardinal;
    Steps: Cardinal;
  end;

function NextValue(Value: Integer): Integer;
begin
  if (Value and 1) = 0 then
    Result := Value shr 1
  else
    Result := Value * 3 + 1;
end;

function Iterate(Value: Integer; Steps: Cardinal): Integer;
var
  Step: Cardinal;
begin
  Result := Value;
  for Step := 1 to Steps do
    Result := NextValue(Result);
end;

[LocalSize(64, 1, 1)]
procedure Main;
var
  Index: Cardinal;
begin
  Index := GlobalInvocationID.X;
  if Index < Params.Count then
    Data[Index] := Iterate(Data[Index], Params.Steps);
end;
