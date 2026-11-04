// This exact file is compiled by both Delphi and PasToSPIRV.
function RotateRight(Value, Shift: Cardinal): Cardinal;
var
  Count: Cardinal;
begin
  Count := Shift and 31;
  Result := (Value shr Count) or (Value shl ((Cardinal(32) - Count) and 31));
end;

function MixBits(Value, Rounds: Cardinal): Cardinal;
var
  I: Cardinal;
begin
  Result := Value;
  for I := 1 to Rounds do
  begin
    Result := Cardinal((Result xor RotateRight(Result, 13)) * Cardinal($85EBCA6B));
    Result := RotateRight(Result, 7) xor Cardinal($9E3779B9);
  end;
end;
