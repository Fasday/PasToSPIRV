uses M;
type TData = M.record Value: Integer; end;
procedure Main;
var Value: TData;
begin
  Value := Default(TData);
end;
