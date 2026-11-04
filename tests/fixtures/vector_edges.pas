var
  [Binding(0, 0), WriteOnly]
  OutputData: array of Cardinal;

function Bump(Value: Integer3): Integer3;
begin
  Value.X := Value.X + 10;
  Result := Value + 1;
end;

function Pair(A, B: Single): Single2;
begin
  Result := Single2(A, B);
end;

procedure Main;
var
  I: Integer4;
  U: Cardinal4;
  V: Integer3;
  W: Integer3;
  F: Single3;
begin
  if GlobalInvocationID.X = 0 then
  begin
    I := Abs(Integer4(-2147483648, -1, 2, 7));
    U := Cardinal4(I);
    OutputData[0] := U.X;
    OutputData[1] := U.Y;
    OutputData[2] := U.Z;
    OutputData[3] := U.W;

    U := Cardinal4($FFFFFFFF, 0, 1, 32) + 1;
    OutputData[4] := U.X;
    OutputData[5] := U.Y;
    OutputData[6] := U.Z;
    OutputData[7] := U.W;

    I := Integer4(-1, 1, 2, 3) shr Integer4(1, 32, 33, -1);
    OutputData[8] := Cardinal(I.X);
    OutputData[9] := Cardinal(I.Y);
    OutputData[10] := Cardinal(I.Z);
    OutputData[11] := Cardinal(I.W);
    OutputData[12] := (Cardinal4(1) shl 33).Z;

    V := Integer3(1, 2, 3);
    W := Bump(V);
    OutputData[13] := Cardinal(V.X);
    OutputData[14] := Cardinal(W.X);
    OutputData[15] := Cardinal(W.Y);
    OutputData[16] := Cardinal(W.Z);

    F := Single3(0);
    F.X := 2;
    F.Y := 4;
    F.Z := 6;
    F := F / 2;
    OutputData[17] := Cardinal(F.X);
    OutputData[18] := Cardinal(F.Y);
    OutputData[19] := Cardinal(F.Z);
    OutputData[20] := Cardinal(Pair(3, 7).Y);

    I := Integer4(-7, 7, -7, 7) mod Integer4(3, 3, -3, -3);
    OutputData[21] := Cardinal(I.X);
    OutputData[22] := Cardinal(I.Y);
    OutputData[23] := Cardinal(I.Z);
    OutputData[24] := Cardinal(I.W);

    V := Clamp(Integer3(-7, 0, 9), -2, 2);
    OutputData[25] := Cardinal(V.X);
    OutputData[26] := Cardinal(V.Y);
    OutputData[27] := Cardinal(V.Z);
    U := Max(Min(Cardinal4(0, 3, 8, $FFFFFFFF), 7), 2);
    OutputData[28] := U.X;
    OutputData[29] := U.Y;
    OutputData[30] := U.Z;
    OutputData[31] := U.W;

    if Single3(1, 2, 3) = Single3(Integer3(1, 2, 3)) then
      OutputData[32] := 1
    else
      OutputData[32] := 0;
    if Integer3(1, 2, 3) <> Integer3(1, 2, 4) then
      OutputData[33] := 1
    else
      OutputData[33] := 0;
    U := Abs(Cardinal4(1, 2, 3, $FFFFFFFF));
    OutputData[34] := U.W;
    U := Cardinal4(not Integer4(0));
    OutputData[35] := U.X;
    OutputData[36] := GlobalInvocationID.Z;
  end;
end;
