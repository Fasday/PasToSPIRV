var
  [Binding(0, 0), WriteOnly]
  OutputData: array of Cardinal;

function CountUp(First, Last: Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  for I := First to Last do
    Result := Result + 1;
end;

function CountDown(First, Last: Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  for I := First downto Last do
    Result := Result + 1;
end;

function CountUpUnsigned(First, Last: Cardinal): Cardinal;
var
  I: Cardinal;
begin
  Result := 0;
  for I := First to Last do
    Result := Result + 1;
end;

function CountDownUnsigned(First, Last: Cardinal): Cardinal;
var
  I: Cardinal;
begin
  Result := 0;
  for I := First downto Last do
    Result := Result + 1;
end;

procedure Main;
var
  I: Integer;
  J: Integer;
  Limit: Integer;
  Sum: Integer;
begin
  if GlobalInvocationID.X = 0 then
  begin
    OutputData[0] := CountUp(2147483646, 2147483647);
    OutputData[1] := CountDown(-2147483647, -2147483648);
    OutputData[2] := CountUp(5, 4);
    OutputData[3] := CountDown(4, 5);
    OutputData[4] := CountUpUnsigned($FFFFFFFE, $FFFFFFFF);
    OutputData[5] := CountDownUnsigned(1, 0);
    OutputData[6] := CountUpUnsigned(1, 0);
    OutputData[7] := CountDownUnsigned(0, 1);
    OutputData[8] := CountUp(0, 0);
    OutputData[9] := CountUpUnsigned($FFFFFFFF, $FFFFFFFF);
    OutputData[10] := CountDown(-2147483648, -2147483648);
    OutputData[11] := CountDownUnsigned(0, 0);

    Limit := 3;
    Sum := 0;
    for I := 1 to Limit do
    begin
      Sum := Sum + I;
      Limit := 0;
    end;
    OutputData[12] := Cardinal(Sum);

    J := 2;
    Sum := 0;
    for I := J to 3 do
    begin
      Sum := Sum + I;
      J := 100;
    end;
    OutputData[13] := Cardinal(Sum);

    // The final expression observes the old I, before assigning the start.
    I := 2;
    Sum := 0;
    for I := 0 to I do
      Sum := Sum + 1;
    OutputData[14] := Cardinal(Sum);

    Sum := 0;
    for I := 1 to 2 do
      for J := 3 downto 1 do
        Sum := Sum + I * J;
    OutputData[15] := Cardinal(Sum);
  end;
end;
