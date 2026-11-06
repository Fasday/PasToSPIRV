var
  [Binding(0,0)] Source: CombinedTexture2D;
  [Binding(0,1), WriteOnly] Target: array of Single4;

[LocalSize(1,1,1)]
procedure Main;
begin
  Target[0] := SampleLevel(Source, Single2(0.5), 0.0);
end;
