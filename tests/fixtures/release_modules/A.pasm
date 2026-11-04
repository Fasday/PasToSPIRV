module A;
const N = 3;
type TData = record Value: Cardinal; end;
function F(Value: Cardinal): Cardinal;
begin Result := Value + N; end;
