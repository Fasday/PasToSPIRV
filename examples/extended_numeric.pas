// Optional Vulkan 1.2 scalar/storage profile; the host enables reflected features.
var
  [Binding(0, 0), ReadWrite] Bytes: array of Byte;
  [Binding(0, 1), ReadWrite] Words: array of Word;
  [Binding(0, 2), ReadWrite] Wide: array of UInt64;
  [Binding(0, 3), ReadWrite] Reals: array of Double;

[Vulkan12, StrictFloat, LocalSize(64, 1, 1)]
procedure Main;
var
  I: Cardinal;
  Signed: Int64;
begin
  I := GlobalInvocationID.X;
  Bytes[I] := Byte(Cardinal(Bytes[I]) + 1);
  Words[I] := Word(Cardinal(Words[I]) xor $1234);
  Wide[I] := (Wide[I] shl 40) or UInt64(I);
  Signed := Round(Reals[I]);
  Reals[I] := Double(Signed) + 0.125d;
end;
