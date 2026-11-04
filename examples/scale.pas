// Binding arguments are (descriptor set, binding).
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

[LocalSize(64, 1, 1)]
procedure Main;
var
  Index: Cardinal;
begin
  Index := GlobalInvocationID.X;
  if Index < Params.Count then
    OutputData[Index] := InputData[Index] * Params.Scale;
end;
