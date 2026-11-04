type
  TPair = record
    A: Integer;
    B: Integer;
  end;
var
  [Binding(0, 0), ReadWrite] Data: array of Integer;

procedure Change(var A: Integer; out B: Integer);
begin
  A := A + 2;
  B := A * 3;
  if A < 0 then Exit;
  A := A + 1;
end;

function ReadData: Integer;
begin
  Exit(Data[GlobalInvocationID.X]);
end;

[Vulkan12]
procedure Main;
var
  P: TPair;
  I: Integer;
begin
  P := Default(TPair);
  P.A := ReadData();
  Change(P.A, P.B);
  for I := 0 to 8 do
  begin
    if I = 2 then Continue;
    if I = 5 then Break;
    P.B := P.B + I;
  end;
  repeat
    P.A := P.A - 1;
  until P.A <= 0;
  case P.B mod 3 of
    0: P.B := P.B + 10;
    1, 2: P.B := P.B + 20;
  else
    P.B := 99;
  end;
  Data[GlobalInvocationID.X] := P.B;
end;
