var
  [Binding(0,0),ReadWrite,Aliased] Bytes: array of Byte;
  [Binding(0,1),ReadWrite,Aliased] Words: array of Word;
  [Binding(0,2),ReadWrite,Aliased] Wide: array of Cardinal;
  [Binding(0,3),WriteOnly] Output: array of Cardinal;

function ReadWord(I: Cardinal): Cardinal;
begin Result := Cardinal(Words[I]); end;

[Vulkan12,LocalSize(64,1,1)]
procedure Main;
var I: Cardinal;
begin
  I := GlobalInvocationID.X;
  Bytes[I*4] := Byte(I);
  Bytes[I*4+1] := Byte(I+1);
  Words[I*2+1] := Word($AB00 + I);
  BufferMemoryBarrier;
  Output[I*2] := Wide[I];
  Output[I*2+1] := ReadWord(I*2);
end;
