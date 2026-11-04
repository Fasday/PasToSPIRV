type
  TTable = array[0..3] of Integer;
const
  Weights: TTable = (2, 4, 8, 16);
var
  [Binding(0, 0), WriteOnly] Output: array of Integer;

function Weight(I: Cardinal): Integer;
begin
  Result := Weights[I and 3];
end;

procedure Main;
begin
  Output[GlobalInvocationID.X] := Weight(GlobalInvocationID.X);
end;
