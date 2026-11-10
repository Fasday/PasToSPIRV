// Interface coverage for tests/vulkan_graphics.py: positions come from VertexIndex,
// clip-space w differs per vertex (so smooth and NoPerspective interpolation differ),
// and integer varyings are Flat. The test also draws with corners 1 and 2 exchanged.
var
  [Input, Location(0)] InPosition: Single3;
  [Input, Location(1)] InColor: Single4;
  [Input, Builtin(VertexIndex)] VI: Integer;
  [Input, Builtin(InstanceIndex)] II: Integer;
  [Output, Builtin(Position)] ClipPosition: Single4;
  [Output, Builtin(PointSize)] Size: Single;
  [Output, Location(0), Flat] Id: Integer2;
  [Output, Location(1), Flat] Tag: Cardinal;
  [Output, Location(2)] Smooth: Single;
  [Output, Location(3), NoPerspective] Linear: Single;
  [Output, Location(4)] Tint: Single4;

function Corner(Index: Integer): Single2;
begin
  case Index of
    0: Result := Single2(-1.0, -1.0);
    1: Result := Single2(3.0, -1.0);
  else
    Result := Single2(-1.0, 3.0);
  end;
end;

[Vertex]
procedure Main;
var
  W: Single;
begin
  W := 1.0 + Single(VI);
  ClipPosition := Single4(Corner(VI) * W, 0.0, W);
  Size := 1.0;
  Id := Integer2(VI + 7, II + 40);
  Tag := Cardinal(VI) + 200;
  Smooth := Single(VI);
  Linear := Single(VI);
  Tint := InColor;
end;
