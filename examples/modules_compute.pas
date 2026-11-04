uses SharedTypes, SharedMath, SharedBits;

var
  [Binding(0, 0), ReadOnly]
  InputData: array of Cardinal;
  [Binding(0, 1), WriteOnly]
  OutputData: array of Cardinal;
  [Binding(0, 2), ReadWrite]
  FloatData: array of Single;
  [PushConstant]
  Params: TSharedParams;

procedure Main;
var
  Index: Cardinal;
begin
  Index := GlobalInvocationID.X;
  if Index < Params.Count then
  begin
    OutputData[Index] := TransformCode(InputData[Index], Params.Rounds);
    FloatData[Index] := ScaleValue(FloatData[Index], Params.Scale);
  end;
end;
