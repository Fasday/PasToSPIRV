var
  [Binding(0, 0), WriteOnly]
  OutputData: array of Cardinal;

function One: Integer;
begin
  Result := 1;
end;

function Two(): Integer;
begin
  Result := One() + 1;
end;

function Add(A, B: Integer): Integer;
begin
  Result := A + B;
end;

function Grouped(A, B: Integer; Bias: Cardinal): Cardinal;
begin
  Result := Cardinal(Add(A, B)) + Bias;
end;

function Scale(Value, Factor: Single): Single;
begin
  Result := Value * Factor;
end;

function Increment(Value: Integer): Integer;
begin
  Value := Value + 1;
  Result := Value;
end;

function Positive(Value: Integer): Boolean;
begin
  Result := Value > 0;
end;

function Negate(Value: Boolean): Boolean;
begin
  Result := not Value;
end;

function Choose(Value: Integer): Integer;
begin
  if Positive(Value) then
    Result := Value
  else
    Result := -Value;
end;

function Triangular(Count: Cardinal): Cardinal;
begin
  Result := 0;
  while Count > 0 do
  begin
    Result := Result + Count;
    Count := Count - 1;
  end;
end;

function IndexValue(Value: Cardinal): Cardinal;
begin
  Result := Value;
end;

procedure Main;
var
  I: Integer;
begin
  if GlobalInvocationID.X = 0 then
  begin
    OutputData[0] := Cardinal(One());
    OutputData[1] := Cardinal(Add(Two(), One()));
    OutputData[2] := Grouped(1, 2, 3);
    OutputData[3] := Cardinal(Scale(4, 2.5));
    I := 10;
    OutputData[4] := Cardinal(Increment(I));
    OutputData[5] := Cardinal(I);
    if Positive(-3) then
      OutputData[6] := 1
    else
      OutputData[6] := 0;
    if Negate(Positive(-3)) then
      OutputData[7] := 1
    else
      OutputData[7] := 0;
    OutputData[8] := Cardinal(Choose(-8));
    OutputData[9] := Triangular(3);
    OutputData[IndexValue(10)] := Cardinal(Add(20, Increment(1)));
    OutputData[11] := Cardinal(Scale(2, Scale(3, 0.5)));
  end;
end;
