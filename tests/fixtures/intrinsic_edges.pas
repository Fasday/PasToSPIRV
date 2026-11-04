var
  [Binding(0, 0), ReadOnly]
  InputData: array of Single;
  [Binding(0, 1), WriteOnly]
  OutputData: array of Single;

procedure Main;
var
  Value: Single4;
  Root: Single4;
begin
  if GlobalInvocationID.X = 0 then
  begin
    Value := Abs(Single4(-2, InputData[1], InputData[0], 4));
    OutputData[0] := Value.X;
    OutputData[1] := Value.Y;
    OutputData[2] := Value.Z;
    OutputData[3] := Value.W;
    OutputData[4] := Min(InputData[0], 3.0);
    OutputData[5] := Min(3.0, InputData[0]);
    OutputData[6] := Max(InputData[0], 3.0);
    OutputData[7] := Max(3.0, InputData[0]);
    OutputData[8] := Min(InputData[0], InputData[0]);
    OutputData[9] := Sqrt(0);
    OutputData[10] := Sqrt(4);
    OutputData[11] := Dot(Single2(3, 4), Single2(3, 4));
    OutputData[12] := Sqrt(Dot(Single2(3, 4), Single2(3, 4)));
    OutputData[13] := Clamp(-2.0, -1.0, 1.0);
    OutputData[14] := Clamp(2.0, -1.0, 1.0);
    OutputData[15] := Abs(InputData[1]);
    Root := Sqrt(Integer4(0, 1, 4, 9));
    OutputData[16] := Root.X;
    OutputData[17] := Root.Y;
    OutputData[18] := Root.Z;
    OutputData[19] := Root.W;
    OutputData[20] := Dot(Integer3(1, 2, 3), Cardinal3(4, 5, 6));
    Value := Clamp(Single4(-2.0, -0.5, 0.5, 2.0), -1.0, 1.0);
    OutputData[21] := Value.X;
    OutputData[22] := Value.Y;
    OutputData[23] := Value.Z;
    OutputData[24] := Value.W;
    if Single2(InputData[0], 1) = Single2(InputData[0], 1) then
      OutputData[25] := 1.0
    else
      OutputData[25] := 0.0;
    if Single2(InputData[0], 1) <> Single2(InputData[0], 1) then
      OutputData[26] := 1.0
    else
      OutputData[26] := 0.0;
  end;
end;
