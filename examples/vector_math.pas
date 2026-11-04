// Each input item has 3 scalar floats; each output has XYZ and its length.
var
  [Binding(0, 0), ReadOnly]
  InputData: array of Single;

  [Binding(0, 1), WriteOnly]
  OutputData: array of Single;

  [PushConstant]
  Params: record
    Count: Cardinal;
    Scale: Single;
  end;

function Transform(Value: Single3; Factor: Single): Single3;
begin
  Result := Clamp(Value * Factor, -1.0, 1.0);
end;

function LengthOf(Value: Single3): Single;
begin
  Result := Sqrt(Dot(Value, Value));
end;

procedure Main;
var
  Index: Cardinal;
  InputBase: Cardinal;
  OutputBase: Cardinal;
  Value: Single3;
begin
  Index := GlobalInvocationID.X;
  if Index < Params.Count then
  begin
    InputBase := Index * 3;
    OutputBase := Index * 4;
    Value := Single3(InputData[InputBase], InputData[InputBase + 1], InputData[InputBase + 2]);
    Value := Transform(Value, Params.Scale);
    OutputData[OutputBase] := Value.X;
    OutputData[OutputBase + 1] := Value.Y;
    OutputData[OutputBase + 2] := Value.Z;
    OutputData[OutputBase + 3] := LengthOf(Value);
  end;
end;
