type TScratch = array[0..3] of Cardinal;
var [Shared] Scratch: TScratch;
function HiddenWrite: Cardinal;
begin
  Scratch[0] := 123;
  Result := Scratch[0];
end;
procedure Main;
var Value: Cardinal;
begin
  Value := HiddenWrite();
end;
