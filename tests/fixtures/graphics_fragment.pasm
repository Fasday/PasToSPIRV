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
  var Gradient: Single := DdxFine(Pixel.X) + DdyFine(Pixel.Y);
  Color := VertexColor * Gradient;
  Depth := 0.5;
end;
