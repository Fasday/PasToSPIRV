// Shared Delphi/PasToSPIRV integer area resampling. Host validates dimensions
// 1..65535, at most 64 Mi pixels, and destination <= source on each axis.
// Products of coordinates fit Cardinal; each weighted channel sum <= 255*65535.
// Filtering is separable in encoded (sRGB-like) channel space, rounded to 8 bits
// after each pass. Premultiplied alpha avoids dark/colored transparent fringes.

function ThumbnailWeight(Sample, First, Last, Scale: Cardinal): Cardinal;
var
  Left: Cardinal;
  Right: Cardinal;
begin
  Left := Sample * Scale;
  if Left < First then
    Left := First;
  Right := (Sample + 1) * Scale;
  if Right > Last then
    Right := Last;
  Result := Right - Left;
end;

function ThumbnailPremultiply(Pixel: Cardinal): Cardinal;
var
  Alpha: Cardinal;
begin
  Alpha := Pixel shr 24;
  Result := (Alpha shl 24) or
    (((((Pixel shr 16) and 255) * Alpha + 127) div 255) shl 16) or
    (((((Pixel shr 8) and 255) * Alpha + 127) div 255) shl 8) or
    (((Pixel and 255) * Alpha + 127) div 255);
end;

function ThumbnailPack(Blue, Green, Red, Alpha, Divisor: Cardinal): Cardinal;
begin
  Result := ((Blue + Divisor div 2) div Divisor) or
    (((Green + Divisor div 2) div Divisor) shl 8) or
    (((Red + Divisor div 2) div Divisor) shl 16) or
    (((Alpha + Divisor div 2) div Divisor) shl 24);
end;

function ThumbnailStraightChannel(Value, Alpha: Cardinal): Cardinal;
begin
  Result := (Value * 255 + Alpha div 2) div Alpha;
  if Result > 255 then
    Result := 255;
end;

function ThumbnailUnpremultiply(Pixel: Cardinal): Cardinal;
var
  Alpha: Cardinal;
begin
  Alpha := Pixel shr 24;
  if Alpha = 0 then
    Result := 0
  else
    Result := (Alpha shl 24) or
      (ThumbnailStraightChannel((Pixel shr 16) and 255, Alpha) shl 16) or
      (ThumbnailStraightChannel((Pixel shr 8) and 255, Alpha) shl 8) or
      ThumbnailStraightChannel(Pixel and 255, Alpha);
end;
