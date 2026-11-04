function TransformCode(Value, Rounds: Cardinal): Cardinal;
begin
  Result := MixBits(Value, Rounds);
end;

function ScaleValue(Value, Factor: Single): Single;
begin
  Result := Value * Factor;
  if Result < -1.0 then
    Result := -1.0
  else if Result > 1.0 then
    Result := 1.0;
end;
