// Pencil-sketch math shared verbatim by the Delphi CPU path (SketchCPU.pas)
// and the PasToSPIRV shader (sketch.pas via SketchMath.pasm).
// Integer-only, so both paths produce bit-identical pixels.
// Pixels are 32-bit BGRA as delivered by WIC: blue in the low byte.
// Radius is limited to 1..32 by the host, so no intermediate exceeds 2^31.

// Rec. 601 luma, 8-bit fixed point with rounding.
function SketchLuma(Pixel: Cardinal): Cardinal;
begin
  Result := ((Pixel and $FF) * 29 + ((Pixel shr 8) and $FF) * 150 +
    ((Pixel shr 16) and $FF) * 77 + 128) shr 8;
end;

// Triangle (tent) filter weight of tap 0..2*Radius; the weights sum to (Radius+1)^2.
function SketchWeight(Tap, Radius: Cardinal): Cardinal;
begin
  if Tap < Radius then
    Result := Tap + 1
  else
    Result := 2 * Radius + 1 - Tap;
end;

// Coordinate of tap 0..2*Radius around Position, clamped to 0..Count-1.
function SketchSample(Position, Tap, Radius, Count: Cardinal): Cardinal;
begin
  if Position + Tap < Radius then
    Result := 0
  else
  begin
    Result := Position + Tap - Radius;
    if Result >= Count then
      Result := Count - 1;
  end;
end;

// Divides a separable horizontal+vertical tent sum back to 0..255, rounded.
function SketchNormalize(Sum, Radius: Cardinal): Cardinal;
var
  Divisor: Cardinal;
begin
  Divisor := (Radius + 1) * (Radius + 1) * (Radius + 1) * (Radius + 1);
  Result := (Sum + Divisor div 2) div Divisor;
end;

// Color dodge of the gray image with its blurred negative: the pencil effect.
function SketchDodge(Gray, InvertedBlur: Cardinal): Cardinal;
begin
  if InvertedBlur >= 255 then
    Result := 255
  else
  begin
    Result := (Gray * 255 + (255 - InvertedBlur) div 2) div (255 - InvertedBlur);
    if Result > 255 then
      Result := 255;
  end;
end;

// Opaque gray BGRA pixel.
function SketchPack(Value: Cardinal): Cardinal;
begin
  Result := $FF000000 or (Value shl 16) or (Value shl 8) or Value;
end;
