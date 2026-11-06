var
  [Binding(0,0)] Source: CombinedTexture2D;
  [Binding(0,1)] Indices: CombinedTexture2DUInt;
  [Binding(0,2), WriteOnly] Target: array of Cardinal4;

[LocalSize(1,1,1)]
procedure Main;
begin
  var Size: Integer2 := TextureSize(Source, 0);
  var Color: Single4 := TexelFetch(Source, Integer2(0), 0);
  var Index: Cardinal4 := TexelFetch(Indices, Integer2(0), 0);
  Target[0] := Cardinal4(RoundFloat(Color * 255.0)) + Index + Cardinal4(Size.X);
end;
