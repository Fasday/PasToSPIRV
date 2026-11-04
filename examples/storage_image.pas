var
  [Binding(0,0), ReadOnly] InputImage: Image2D_R32UInt;
  [Binding(0,1), WriteOnly] OutputImage: Image2D_R32UInt;
[LocalSize(8,4,1)]
procedure Main;
var Position: Integer2; Extent: Integer2; Pixel: Cardinal4;
begin
  Position := Integer2(Integer(GlobalInvocationID.X), Integer(GlobalInvocationID.Y));
  Extent := ImageSize(InputImage);
  if (Position.X < Extent.X) and (Position.Y < Extent.Y) then
  begin
    Pixel := ImageLoad(InputImage, Position);
    ImageStore(OutputImage, Position, Pixel + Cardinal4(1,0,0,0));
  end;
end;
