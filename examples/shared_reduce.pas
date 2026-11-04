const BlockSize = 64;
type TScratch = array[0..BlockSize - 1] of Cardinal;
var
  [Binding(0,0), ReadOnly] InputData: array of Cardinal;
  [Binding(0,1), WriteOnly] OutputData: array of Cardinal;
  [Shared] Scratch: TScratch;
  [PushConstant] Params: record Count: Cardinal; end;
procedure Main;
var Lane: Cardinal; Index: Cardinal;
begin
  Lane := LocalInvocationIndex;
  Index := GlobalInvocationID.X;
  if Index < Params.Count then Scratch[Lane] := InputData[Index] else Scratch[Lane] := 0;
  Barrier;
  if Lane < 32 then Scratch[Lane] := Scratch[Lane] + Scratch[Lane + 32];
  Barrier;
  if Lane < 16 then Scratch[Lane] := Scratch[Lane] + Scratch[Lane + 16];
  Barrier;
  if Lane < 8 then Scratch[Lane] := Scratch[Lane] + Scratch[Lane + 8];
  Barrier;
  if Lane < 4 then Scratch[Lane] := Scratch[Lane] + Scratch[Lane + 4];
  Barrier;
  if Lane < 2 then Scratch[Lane] := Scratch[Lane] + Scratch[Lane + 2];
  Barrier;
  if Lane < 1 then Scratch[Lane] := Scratch[Lane] + Scratch[Lane + 1];
  Barrier;
  if Lane = 0 then OutputData[WorkgroupID.X] := Scratch[0];
end;
