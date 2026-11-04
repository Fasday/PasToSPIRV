type
  TMixed = record
    A: Byte;
    B: Word;
    C: UInt64;
    D: Single;
    E: Double;
  end;
var
  [Binding(0,0)] Data: array of TMixed;
  [Binding(0,1)] Bytes: array of Byte;
  [Binding(0,2)] Words: array of Word;
  [Binding(0,3)] Signed: array of Int64;
  [PushConstant] Params: TMixed;
[Vulkan12]
procedure Main;
begin
  Data[GlobalInvocationID.X] := Params;
end;
