var
  [Binding(0, 0)] Values: array of Cardinal;
  [Shared] Mask: array[0..0] of Integer;

procedure UpdateBuffer;
begin
  Values[1] := AtomicOr(Values[0], $A0);
  Values[2] := AtomicAnd(Values[0], $CF);
  Values[5] := AtomicAdd(Values[0], 1);
end;

[LocalSize(1, 1, 1)]
procedure Main;
var
  Element: Integer;

  function UpdateShared: Integer;
  begin
    AtomicOr(Mask[Element], 5);
    Result := AtomicAnd(Mask[Element], -2);
  end;

begin
  Element := 0;
  Mask[0] := 8;
  Barrier;
  UpdateBuffer;
  Values[3] := Cardinal(UpdateShared);
  Values[4] := Cardinal(Mask[0]);
end;
