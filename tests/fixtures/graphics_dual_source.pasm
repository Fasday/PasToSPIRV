var
  [Output, Location(0), Index(0)] Color: Single4;
  [Output, Location(0), Index(1)] Factor: Single4;

[Fragment, EarlyFragmentTests]
procedure Main;
begin
  Color := Single4(1.0);
  Factor := Single4(0.5);
end;
