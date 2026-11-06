var
  [Input, Location(0)] InPosition: Single3;
  [Input, Location(1)] InColor: Single4;
  [Output, Builtin(Position)] ClipPosition: Single4;
  [Output, Location(0), NoPerspective] VertexColor: Single4;

[Vertex]
procedure Main;
begin
  ClipPosition := Single4(InPosition, 1.0);
  VertexColor := InColor;
end;
