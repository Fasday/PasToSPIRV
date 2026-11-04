// Pencil sketch in three dispatches of one pipeline, selected by Params.Pass:
//   0: gray     Gray[i]       := Luma(Source[i])
//   1: blur X   Horizontal[i] := tent sum of (255 - Gray) along the row
//   2: blur Y   Target[i]     := Dodge(Gray[i], normalized tent sum of Horizontal)
// The host inserts a compute->compute barrier between dispatches.
// Passes 3 and 4 make a color thumbnail: area filter X and Y, premultiplied alpha.
uses SketchMath, ThumbnailMath;

var
  [Binding(0, 0), ReadOnly] Source: array of Cardinal;
  [Binding(0, 1), ReadWrite] Gray: array of Cardinal;
  [Binding(0, 2), ReadWrite] Horizontal: array of Cardinal;
  [Binding(0, 3), WriteOnly] Target: array of Cardinal;

  [PushConstant]
  Params: record
    Width: Cardinal;
    Height: Cardinal;
    Radius: Cardinal;
    Pass: Cardinal;
    TargetWidth: Cardinal;
    TargetHeight: Cardinal;
  end;

[LocalSize(16, 16, 1)]
procedure Main;
var
  X: Cardinal;
  Y: Cardinal;
  Index: Cardinal;
  Tap: Cardinal;
  Sum: Cardinal;
  First: Cardinal;
  Last: Cardinal;
  Weight: Cardinal;
  Pixel: Cardinal;
  Blue: Cardinal;
  Green: Cardinal;
  Red: Cardinal;
  Alpha: Cardinal;
begin
  X := GlobalInvocationID.X;
  Y := GlobalInvocationID.Y;
  if Params.Pass = 3 then
  begin
    if (X < Params.TargetWidth) and (Y < Params.Height) then
    begin
      First := X * Params.Width;
      Last := (X + 1) * Params.Width;
      Blue := 0;
      Green := 0;
      Red := 0;
      Alpha := 0;
      for Tap := First div Params.TargetWidth to (Last - 1) div Params.TargetWidth do
      begin
        Weight := ThumbnailWeight(Tap, First, Last, Params.TargetWidth);
        Pixel := Source[Y * Params.Width + Tap];
        if (Params.TargetWidth <> Params.Width) or (Params.TargetHeight <> Params.Height) then
          Pixel := ThumbnailPremultiply(Pixel);
        Blue := Blue + (Pixel and 255) * Weight;
        Green := Green + ((Pixel shr 8) and 255) * Weight;
        Red := Red + ((Pixel shr 16) and 255) * Weight;
        Alpha := Alpha + (Pixel shr 24) * Weight;
      end;
      Gray[Y * Params.TargetWidth + X] := ThumbnailPack(Blue, Green, Red, Alpha, Params.Width);
    end;
  end
  else if Params.Pass = 4 then
  begin
    if (X < Params.TargetWidth) and (Y < Params.TargetHeight) then
    begin
      First := Y * Params.Height;
      Last := (Y + 1) * Params.Height;
      Blue := 0;
      Green := 0;
      Red := 0;
      Alpha := 0;
      for Tap := First div Params.TargetHeight to (Last - 1) div Params.TargetHeight do
      begin
        Weight := ThumbnailWeight(Tap, First, Last, Params.TargetHeight);
        Pixel := Gray[Tap * Params.TargetWidth + X];
        Blue := Blue + (Pixel and 255) * Weight;
        Green := Green + ((Pixel shr 8) and 255) * Weight;
        Red := Red + ((Pixel shr 16) and 255) * Weight;
        Alpha := Alpha + (Pixel shr 24) * Weight;
      end;
      Pixel := ThumbnailPack(Blue, Green, Red, Alpha, Params.Height);
      if (Params.TargetWidth <> Params.Width) or (Params.TargetHeight <> Params.Height) then
        Pixel := ThumbnailUnpremultiply(Pixel);
      Target[Y * Params.TargetWidth + X] := Pixel;
    end;
  end
  else if (X < Params.Width) and (Y < Params.Height) then
  begin
    Index := Y * Params.Width + X;
    if Params.Pass = 0 then
      Gray[Index] := SketchLuma(Source[Index])
    else if Params.Pass = 1 then
    begin
      Sum := 0;
      for Tap := 0 to 2 * Params.Radius do
        Sum := Sum + SketchWeight(Tap, Params.Radius) *
          (255 - Gray[Y * Params.Width + SketchSample(X, Tap, Params.Radius, Params.Width)]);
      Horizontal[Index] := Sum;
    end
    else
    begin
      Sum := 0;
      for Tap := 0 to 2 * Params.Radius do
        Sum := Sum + SketchWeight(Tap, Params.Radius) *
          Horizontal[SketchSample(Y, Tap, Params.Radius, Params.Height) * Params.Width + X];
      Target[Index] := SketchPack(SketchDodge(Gray[Index], SketchNormalize(Sum, Params.Radius)));
    end;
  end;
end;
