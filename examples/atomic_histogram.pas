const
  BinCount: Cardinal = 16;
  BlockSize: Cardinal = 8 * 8;
var
  [Binding(0,0), ReadOnly] InputData: array of Cardinal;
  [Binding(0,1), ReadWrite] Counts: array of Cardinal;
  [PushConstant] Params: record Count: Cardinal; end;
[LocalSize(BlockSize,1,1)]
procedure Main;
var Index: Cardinal;
begin
  Index := GlobalInvocationID.X;
  if Index < Params.Count then
    AtomicAdd(Counts[InputData[Index] mod BinCount], 1);
end;
