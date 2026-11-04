var [Binding(0,0)] Data: array of Cardinal;
procedure Main;
begin
  if GlobalInvocationID.X = 0 then
  begin
    Data[0] := Cardinal(1 shl 31);
    Data[1] := Cardinal(1 shl 2147483647);
    Data[2] := Cardinal((Integer(1) shl Integer($7FFFFFFF)) xor
      (not (Integer($7FFFFFFF) - Integer($FFFFFFFF))));
  end;
end;
