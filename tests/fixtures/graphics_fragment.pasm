var
  [Input, Location(0), NoPerspective] VertexColor: Single4;
  [Input, Builtin(FragCoord)] Pixel: Single4;
  [Output, Location(0)] Color: Single4;
  [Output, Builtin(FragDepth)] Depth: Single;

procedure Reject;
begin
  if Pixel.X < 0.0 then
    Discard;
end;

[Fragment]
procedure Main;
begin
  Reject;
  // d/dx = 1 and d/dy = 2: exchanging the two derivatives would change the result.
  var Mixed: Single := Pixel.X + 2.0 * Pixel.Y;
  var Gradient: Single := (DdxFine(Mixed) + 4.0 * DdyFine(Mixed)) / 4.5;
  Color := VertexColor * Gradient;
  Depth := 0.5;
end;
