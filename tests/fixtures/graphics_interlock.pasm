var
  [Input, Builtin(FragCoord)] Pixel: Single4;
  [Binding(0,0), Coherent] Target: Image2D_RGBA8;

[Fragment, PixelInterlockOrdered, Vulkan11]
procedure Main;
begin
  if Pixel.X < 0.0 then
    Discard;
  Interlock begin
    var Value: Single4 := ImageLoad(Target, Integer2(Pixel.XY));
    ImageStore(Target, Integer2(Pixel.XY), Value + Single4(0.1, 0.0, 0.0, 0.0));
  end;
end;
