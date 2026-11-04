var
  [Binding(0, 0), WriteOnly]
  OutputData: array of Cardinal;

procedure Main;
var
  I: Integer;
begin
  if GlobalInvocationID.X = 0 then
  begin
    OutputData[0] := Cardinal(-7 div 3);
    OutputData[1] := Cardinal(-7 mod 3);
    OutputData[2] := Cardinal(-1 shr 1);
    OutputData[3] := Cardinal(1 shl 32);
    OutputData[4] := Cardinal(1 shl 33);
    OutputData[5] := $FFFFFFFF + 1;
    OutputData[6] := Cardinal(-2147483648 - 1);
    OutputData[7] := Cardinal(-(-2147483648));
    I := -7;
    OutputData[8] := Cardinal(I);
    I := Integer(-7.75);
    OutputData[9] := Cardinal(I);
    OutputData[10] := Cardinal(7.75);
    OutputData[11] := Cardinal(2 shl -1);
    OutputData[12] := Cardinal(-7 mod -3);
    OutputData[13] := Cardinal(7 mod -3);
    OutputData[14] := Cardinal(-7 div -3);
    OutputData[15] := Cardinal(1 shr -1);
  end;
end;
