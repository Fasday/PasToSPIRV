type
  TTriple = array[0..2] of Integer;
  TLocal = record
    Values: TTriple;
    Flag: Boolean;
    Vector: Single2;
  end;

var
  [Binding(0, 0), WriteOnly]
  OutputData: array of Cardinal;

function Build: TLocal;
begin
  Result := Default(TLocal);
  Result.Values[0] := -1;
  Result.Values[1] := 2;
  Result.Values[2] := 3;
  Result.Flag := True;
  Result.Vector := Single2(4, 5);
end;

function Change(Value: TLocal; Index: Integer): TLocal;
begin
  Value.Values[Index] := Value.Values[Index] + 10;
  Result := Value;
end;

function ChangeArray(Value: TTriple): TTriple;
begin
  Value[2] := Value[2] + 20;
  Result := Value;
end;

function Sum(Value: TTriple): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 2 do Result := Result + Value[I];
end;

procedure Main;
var
  Original: TLocal;
  Changed: TLocal;
  Values: TTriple;
  Other: TTriple;
  I: Integer;
begin
  if GlobalInvocationID.X = 0 then
  begin
    Original := Build();
    Changed := Change(Original, 1);
    OutputData[0] := Cardinal(Original.Values[1]);
    OutputData[1] := Cardinal(Changed.Values[1]);
    if Changed.Flag then OutputData[2] := 1 else OutputData[2] := 0;
    OutputData[3] := Cardinal(Changed.Vector.Y);
    Values := Default(TTriple);
    for I := 0 to 2 do Values[I] := I + 1;
    OutputData[4] := Cardinal(Sum(Values));
    Other := ChangeArray(Values);
    OutputData[5] := Cardinal(Values[2]);
    OutputData[6] := Cardinal(Other[2]);
    OutputData[7] := Cardinal(ChangeArray(Values)[1]);
    OutputData[8] := Cardinal(Build().Values[2]);
    OutputData[9] := Cardinal(Default(TLocal).Values[0]);
    OutputData[10] := Cardinal(Default(Single4).Z);
    if Default(Boolean) then OutputData[11] := 1 else OutputData[11] := 0;
  end;
end;
