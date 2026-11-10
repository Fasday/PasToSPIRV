// Interface coverage for tests/vulkan_graphics.py: Flat integer varyings, smooth and
// NoPerspective interpolation, FragCoord, FrontFacing, and Discard inside a loop and
// inside a nested routine of a helper.
var
  [Input, Builtin(FragCoord)] Pixel: Single4;
  [Input, Builtin(FrontFacing)] Front: Boolean;
  [Input, Location(0), Flat] Id: Integer2;
  [Input, Location(1), Flat] Tag: Cardinal;
  [Input, Location(2)] Smooth: Single;
  [Input, Location(3), NoPerspective] Linear: Single;
  [Input, Location(4)] Tint: Single4;
  [Output, Location(0)] Color: Single4;

procedure Reject(Column: Integer);
  procedure Inner;
  begin
    if Column = 5 then
      Discard;
  end;
begin
  Inner;
end;

[Fragment]
procedure Main;
var
  I, Column, Row: Integer;
  Flat: Single;
begin
  Column := Integer(FloorFloat(Pixel.X));
  Row := Integer(FloorFloat(Pixel.Y));
  for I := 0 to 31 do
    if (I = Column) and (I = 9) and (Row >= 8) then
      Discard;
  Reject(Column);
  Flat := Single(Id.X + Id.Y - 47 + Integer(Tag) - 200) * 0.25 + 0.25;
  if Row = 0 then
    Color := Single4(Pixel.X / 32.0, Pixel.Y / 16.0, Tint.X + Tint.Y + Tint.Z, Tint.W)
  else
    Color := Single4(Flat, Smooth * 0.5, Linear * 0.5, if Front then 1.0 else 0.5);
end;
