var
  [Binding(0,0)] Values: array of Cardinal;
  [Binding(0,1)] SignedValues: array of Integer;
procedure Main;
var Previous: Cardinal; SignedPrevious: Integer;
begin
  if GlobalInvocationID.X = 0 then
  begin
    Previous := AtomicExchange(Values[0], 20);
    Values[1] := Previous;
    Values[2] := AtomicCompareExchange(Values[0], 20, 30);
    Values[3] := AtomicCompareExchange(Values[0], 20, 40);
    SignedPrevious := AtomicAdd(SignedValues[0], -2);
    SignedValues[1] := SignedPrevious;
  end;
end;
