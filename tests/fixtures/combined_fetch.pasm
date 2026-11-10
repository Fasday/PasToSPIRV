// Every texel of three textures, for tests/vulkan_graphics.py: TexelFetch with
// Integer2 and Cardinal2 coordinates on combined float/unsigned and separate
// textures, TextureSize, and combined SampleLevel at texel centres.
var
  [Binding(0,0)] Source: CombinedTexture2D;
  [Binding(0,1)] Indices: CombinedTexture2DUInt;
  [Binding(0,2)] Plain: Texture2D;
  [Binding(0,3), WriteOnly] OutF: array of Single4;
  [Binding(0,4), WriteOnly] OutU: array of Cardinal4;
  [Binding(0,5), WriteOnly] OutS: array of Integer4;

function Center(X, Y: Integer): Single2;
begin
  Result := (Single2(Single(X), Single(Y)) + 0.5) / Single2(5.0, 3.0);
end;

[LocalSize(16,1,1)]
procedure Main;
var
  I, X, Y: Integer;
begin
  I := Integer(GlobalInvocationID.X);
  if I < 15 then
  begin
    X := I mod 5;
    Y := I div 5;
    OutF[I * 4 + 0] := TexelFetch(Source, Integer2(X, Y), 0);
    OutF[I * 4 + 1] := TexelFetch(Source, Cardinal2(Cardinal(X), Cardinal(Y)), 0);
    OutF[I * 4 + 2] := TexelFetch(Plain, Integer2(X and 1, Y and 1), 0);
    OutF[I * 4 + 3] := SampleLevel(Source, Center(X, Y), 0.0);
    OutU[I] := TexelFetch(Indices, Integer2(X mod 4, Y mod 2), 0);
    OutS[I] := Integer4(TextureSize(Source, 0), TextureSize(Indices, 0));
    if I = 0 then
      OutS[15] := Integer4(TextureSize(Plain, 0), 7, 9);
  end;
end;
