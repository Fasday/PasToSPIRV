type
  TItems = array[0..3] of Integer;
  TData = record A: Integer; Items: TItems; end;
var
  [Binding(0,0),WriteOnly] Output: array of Integer;

procedure Pair(var A: Integer; var B: Integer);
begin A := A + 1; B := B * 2; end;

function NextIndex(var I: Integer): Integer;
begin Result := I; I := I + 1; end;

procedure Make(out D: TData);
begin
  D := Default(TData);
  D.A := Integer(GlobalInvocationID.X);
  D.Items[0] := 3; D.Items[1] := 5;
end;

procedure Nested(var D: TData; I: Integer);
begin Pair(D.A, D.Items[I]); end;

procedure Overlap(var D: TData; var A: Integer);
begin D.A := 10; A := A + 1; end;

function Choose(V: Integer): Integer;
begin
  if V < 0 then Exit(-1);
  case V mod 3 of
    0: Exit(7);
    1: Result := 9;
  else Result := 11;
  end;
end;

[Vulkan12,LocalSize(64,1,1)]
procedure Main;
var D: TData; J: Integer; I: Integer; Sum: Integer; O: Cardinal; W: UInt64;
begin
  O := GlobalInvocationID.X * 9;
  Make(D);
  Pair(D.A, D.A);
  Output[O] := D.A;
  Nested(D, 0);
  Output[O+1] := D.Items[0];
  Overlap(D, D.A);
  Output[O+2] := D.A;
  J := 0;
  Pair(D.Items[NextIndex(J)], D.Items[NextIndex(J)]);
  Output[O+3] := J; Output[O+4] := D.Items[0]; Output[O+5] := D.Items[1];
  Sum := 0;
  for I := 0 to 8 do
    case I of
      1: Continue;
      4: Break;
    else Sum := Sum + I;
    end;
  Output[O+6] := Sum;
  repeat
    Sum := Sum - 1;
    if Sum = 3 then Continue;
    if Sum = 1 then Break;
  until Sum <= 0;
  Output[O+7] := Choose(Sum);
  W := $FEDCBA9876543210;
  case W of
    $FEDCBA9876543210: Output[O+8] := 123;
  else Output[O+8] := 0;
  end;
end;
