unit ThumbnailCPU;

// Separable area filter: includes fractional source-pixel coverage, unlike
// nearest/bilinear sampling which aliases badly when shrinking a large image.

{$POINTERMATH ON}

interface

uses
  System.Types;

const
  ThumbnailPresets: array[0..4] of TPoint = ((X: 128; Y: 128), (X: 256; Y: 256),
    (X: 320; Y: 240), (X: 512; Y: 512), (X: 1024; Y: 1024));

function ThumbnailSize(AWidth, AHeight, AMaxWidth, AMaxHeight: Integer): TPoint;
procedure ValidateThumbnailSizes(AWidth, AHeight, ATargetWidth, ATargetHeight: Integer);

type
  TThumbnailCPU = class
  private
    FWidth, FHeight, FTargetWidth, FTargetHeight: Integer;
    FHorizontal: TArray<Cardinal>;
    procedure HorizontalRows(ASource: PCardinal; AFirst, ALast: Integer);
    procedure VerticalRows(ATarget: PCardinal; AFirst, ALast: Integer);
  public
    constructor Create(AWidth, AHeight, ATargetWidth, ATargetHeight: Integer);
    // Output is preallocated by the caller, as with SketchCPU.
    procedure RunSingle(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>);
    procedure RunParallel(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>);
  end;

implementation

uses
  System.SysUtils,
  System.Math,
  System.Threading;

{$I 'ThumbnailMath.inc'}

procedure ValidateThumbnailSizes(AWidth, AHeight, ATargetWidth, ATargetHeight: Integer);
begin
  if (AWidth < 1) or (AHeight < 1) or (AWidth > 65535) or (AHeight > 65535) or
    (Int64(AWidth) * AHeight > 64 * 1024 * 1024) or
    (ATargetWidth < 1) or (ATargetHeight < 1) or
    (ATargetWidth > AWidth) or (ATargetHeight > AHeight) then
    raise EArgumentException.Create('Thumbnail: dimensions must be 1..65535, at most 64 Mi pixels; no upscaling');
end;

function ThumbnailSize(AWidth, AHeight, AMaxWidth, AMaxHeight: Integer): TPoint;
var
  W, H: Integer;
begin
  ValidateThumbnailSizes(AWidth, AHeight, AWidth, AHeight);
  if (AMaxWidth < 1) or (AMaxHeight < 1) or (AMaxWidth > 65535) or (AMaxHeight > 65535) then
    raise EArgumentException.Create('Thumbnail bounds must be in 1..65535');
  W := Min(AWidth, AMaxWidth);
  H := Min(AHeight, AMaxHeight);
  // Integer aspect fit: truncate the secondary dimension, clamp very thin images to 1.
  if Int64(W) * AHeight <= Int64(H) * AWidth then
    Result := Point(W, Max(1, Int64(AHeight) * W div AWidth))
  else
    Result := Point(Max(1, Int64(AWidth) * H div AHeight), H);
end;

constructor TThumbnailCPU.Create(AWidth, AHeight, ATargetWidth, ATargetHeight: Integer);
begin
  inherited Create;
  ValidateThumbnailSizes(AWidth, AHeight, ATargetWidth, ATargetHeight);
  FWidth := AWidth;
  FHeight := AHeight;
  FTargetWidth := ATargetWidth;
  FTargetHeight := ATargetHeight;
  SetLength(FHorizontal, NativeInt(FTargetWidth) * FHeight);
end;

procedure TThumbnailCPU.HorizontalRows(ASource: PCardinal; AFirst, ALast: Integer);
var
  X, Y, Tap: Integer;
  First, Last, Weight, Pixel, Blue, Green, Red, Alpha: Cardinal;
begin
  for Y := AFirst to ALast do
    for X := 0 to FTargetWidth - 1 do
    begin
      First := Cardinal(X) * Cardinal(FWidth);
      Last := Cardinal(X + 1) * Cardinal(FWidth);
      Blue := 0;
      Green := 0;
      Red := 0;
      Alpha := 0;
      for Tap := First div Cardinal(FTargetWidth) to (Last - 1) div Cardinal(FTargetWidth) do
      begin
        Weight := ThumbnailWeight(Tap, First, Last, FTargetWidth);
        // Identity resize preserves even invisible RGB and low-alpha channels exactly.
        Pixel := ASource[NativeInt(Y) * FWidth + Tap];
        if (FTargetWidth <> FWidth) or (FTargetHeight <> FHeight) then
          Pixel := ThumbnailPremultiply(Pixel);
        Inc(Blue, (Pixel and 255) * Weight);
        Inc(Green, ((Pixel shr 8) and 255) * Weight);
        Inc(Red, ((Pixel shr 16) and 255) * Weight);
        Inc(Alpha, (Pixel shr 24) * Weight);
      end;
      FHorizontal[NativeInt(Y) * FTargetWidth + X] := ThumbnailPack(Blue, Green, Red, Alpha, FWidth);
    end;
end;

procedure TThumbnailCPU.VerticalRows(ATarget: PCardinal; AFirst, ALast: Integer);
var
  X, Y, Tap: Integer;
  First, Last, Weight, Pixel, Blue, Green, Red, Alpha: Cardinal;
begin
  for Y := AFirst to ALast do
    for X := 0 to FTargetWidth - 1 do
    begin
      First := Cardinal(Y) * Cardinal(FHeight);
      Last := Cardinal(Y + 1) * Cardinal(FHeight);
      Blue := 0;
      Green := 0;
      Red := 0;
      Alpha := 0;
      for Tap := First div Cardinal(FTargetHeight) to (Last - 1) div Cardinal(FTargetHeight) do
      begin
        Weight := ThumbnailWeight(Tap, First, Last, FTargetHeight);
        Pixel := FHorizontal[NativeInt(Tap) * FTargetWidth + X];
        Inc(Blue, (Pixel and 255) * Weight);
        Inc(Green, ((Pixel shr 8) and 255) * Weight);
        Inc(Red, ((Pixel shr 16) and 255) * Weight);
        Inc(Alpha, (Pixel shr 24) * Weight);
      end;
      Pixel := ThumbnailPack(Blue, Green, Red, Alpha, FHeight);
      if (FTargetWidth <> FWidth) or (FTargetHeight <> FHeight) then
        Pixel := ThumbnailUnpremultiply(Pixel);
      ATarget[NativeInt(Y) * FTargetWidth + X] := Pixel;
    end;
end;

procedure TThumbnailCPU.RunSingle(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>);
begin
  if (Length(ASource) <> NativeInt(FWidth) * FHeight) or
    (Length(ATarget) <> NativeInt(FTargetWidth) * FTargetHeight) then
    raise EArgumentException.Create('Thumbnail pixel counts differ from prepared dimensions');
  HorizontalRows(@ASource[0], 0, FHeight - 1);
  VerticalRows(@ATarget[0], 0, FTargetHeight - 1);
end;

procedure TThumbnailCPU.RunParallel(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>);
const
  BandRows = 16;
var
  Source, Target: PCardinal;
begin
  if (Length(ASource) <> NativeInt(FWidth) * FHeight) or
    (Length(ATarget) <> NativeInt(FTargetWidth) * FTargetHeight) then
    raise EArgumentException.Create('Thumbnail pixel counts differ from prepared dimensions');
  Source := @ASource[0];
  Target := @ATarget[0];
  TParallel.For(0, (FHeight + BandRows - 1) div BandRows - 1,
    procedure(Band: Integer)
    begin
      HorizontalRows(Source, Band * BandRows, Min(FHeight, (Band + 1) * BandRows) - 1);
    end);
  TParallel.For(0, (FTargetHeight + BandRows - 1) div BandRows - 1,
    procedure(Band: Integer)
    begin
      VerticalRows(Target, Band * BandRows, Min(FTargetHeight, (Band + 1) * BandRows) - 1);
    end);
end;

end.
