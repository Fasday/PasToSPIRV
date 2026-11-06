// Entry files may use .pasm too; only library modules have a module header.
var
  [Binding(0,0),WriteOnly] Data: array of Cardinal;
  [PushConstant] P: record
    Bias: Cardinal;
  end;

[LocalSize(64,1,1)]
procedure Main;
var
  I: Cardinal;
begin
  I := GlobalInvocationID.X;
  Data[I] := I * 3 + P.Bias;
end;
