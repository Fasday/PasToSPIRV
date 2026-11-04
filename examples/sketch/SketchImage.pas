unit SketchImage;

// Image input/output through the Windows Imaging Component (WIC):
// any WIC-readable file is converted to 32-bit BGRA; results are saved as PNG.

interface

type
  TImagePixels = record
    Width: Integer;
    Height: Integer;
    Pixels: TArray<Cardinal>; // BGRA, row-major, no padding
  end;

function LoadImage(const AFileName: string): TImagePixels;
procedure SavePng(const AFileName: string; const AImage: TImagePixels);
// Deterministic test picture with gradients, shapes, lines and fine noise.
function SyntheticImage(AWidth, AHeight: Integer): TImagePixels;

implementation

uses
  Winapi.Windows,
  Winapi.ActiveX,
  Winapi.Wincodec,
  System.SysUtils,
  System.Math;

procedure Check(AResult: HRESULT; const AOperation: string);
begin
  if Failed(AResult) then
    raise EOSError.CreateFmt('%s failed: HRESULT $%.8x', [AOperation, Cardinal(AResult)]);
end;

function Factory: IWICImagingFactory;
begin
  Check(CoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER,
    IWICImagingFactory, Result), 'Creating the WIC factory');
end;

function LoadImage(const AFileName: string): TImagePixels;
var
  Decoder: IWICBitmapDecoder;
  Frame: IWICBitmapFrameDecode;
  Converter: IWICFormatConverter;
  Width, Height: UINT;
  Imaging: IWICImagingFactory;
begin
  Imaging := Factory;
  Check(Imaging.CreateDecoderFromFilename(PWideChar(AFileName), GUID_NULL, GENERIC_READ,
    WICDecodeMetadataCacheOnDemand, Decoder), 'Opening ' + AFileName);
  Check(Decoder.GetFrame(0, Frame), 'Reading the first frame');
  Check(Imaging.CreateFormatConverter(Converter), 'Creating a format converter');
  Check(Converter.Initialize(Frame, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
    nil, 0, WICBitmapPaletteTypeCustom), 'Converting to 32bpp BGRA');
  Check(Converter.GetSize(Width, Height), 'Reading the image size');
  if (Width = 0) or (Height = 0) or (UInt64(Width) * Height > 64 * 1024 * 1024) then
    raise EArgumentException.Create('Image must have 1..64 Mi pixels');
  Result.Width := Width;
  Result.Height := Height;
  SetLength(Result.Pixels, NativeInt(Width) * Height);
  Check(Converter.CopyPixels(nil, Width * 4, Width * Height * 4, @Result.Pixels[0]), 'Copying pixels');
end;

procedure SavePng(const AFileName: string; const AImage: TImagePixels);
var
  Imaging: IWICImagingFactory;
  Stream: IWICStream;
  Encoder: IWICBitmapEncoder;
  Frame: IWICBitmapFrameEncode;
  Options: IPropertyBag2;
  Format: TGUID;
begin
  Imaging := Factory;
  Check(Imaging.CreateStream(Stream), 'Creating a WIC stream');
  Check(Stream.InitializeFromFilename(PWideChar(AFileName), GENERIC_WRITE), 'Creating ' + AFileName);
  Check(Imaging.CreateEncoder(GUID_ContainerFormatPng, GUID_NULL, Encoder), 'Creating a PNG encoder');
  Check(Encoder.Initialize(Stream, WICBitmapEncoderNoCache), 'Initializing the PNG encoder');
  Options := nil;
  Check(Encoder.CreateNewFrame(Frame, Options), 'Creating a PNG frame');
  Check(Frame.Initialize(Options), 'Initializing the PNG frame');
  Check(Frame.SetSize(AImage.Width, AImage.Height), 'Setting the PNG size');
  Format := GUID_WICPixelFormat32bppBGRA;
  Check(Frame.SetPixelFormat(Format), 'Setting the PNG pixel format');
  if Format <> GUID_WICPixelFormat32bppBGRA then
    raise EOSError.Create('The PNG encoder does not accept 32bpp BGRA');
  Check(Frame.WritePixels(AImage.Height, AImage.Width * 4, AImage.Width * AImage.Height * 4,
    @AImage.Pixels[0]), 'Writing pixels');
  Check(Frame.Commit, 'Committing the PNG frame');
  Check(Encoder.Commit, 'Committing the PNG file');
end;

function SyntheticImage(AWidth, AHeight: Integer): TImagePixels;
var
  X, Y, I: Integer;
  R, G, B, Noise: Integer;
  Seed: Cardinal;
  DX, DY: Double;
  Circles: array[0..5] of record CX, CY, Radius: Double; R, G, B: Integer; end;
begin
  Result.Width := AWidth;
  Result.Height := AHeight;
  SetLength(Result.Pixels, NativeInt(AWidth) * AHeight);
  Seed := 12345;
  for I := 0 to High(Circles) do
  begin
    Seed := Seed * 1664525 + 1013904223;
    Circles[I].CX := (Seed shr 8 and $FFFF) / 65535 * AWidth;
    Seed := Seed * 1664525 + 1013904223;
    Circles[I].CY := (Seed shr 8 and $FFFF) / 65535 * AHeight;
    Seed := Seed * 1664525 + 1013904223;
    Circles[I].Radius := (0.05 + (Seed shr 8 and $FFFF) / 65535 * 0.2) * Min(AWidth, AHeight);
    Circles[I].R := 40 + I * 35;
    Circles[I].G := 220 - I * 30;
    Circles[I].B := 90 + I * 25;
  end;
  for Y := 0 to AHeight - 1 do
    for X := 0 to AWidth - 1 do
    begin
      // Sky-like vertical gradient with a horizontal tint.
      R := 70 + 120 * X div Max(1, AWidth - 1);
      G := 110 + 100 * Y div Max(1, AHeight - 1);
      B := 200 - 90 * Y div Max(1, AHeight - 1);
      for I := 0 to High(Circles) do
      begin
        DX := X - Circles[I].CX;
        DY := Y - Circles[I].CY;
        if DX * DX + DY * DY < Sqr(Circles[I].Radius) then
        begin
          R := Circles[I].R;
          G := Circles[I].G;
          B := Circles[I].B;
        end;
      end;
      // Diagonal stripes and a grid give the sketch filter edges to find.
      if ((X + Y) div 48) mod 7 = 0 then
      begin
        R := R div 2;
        G := G div 2;
        B := B div 2;
      end;
      if (X mod 160 = 0) or (Y mod 120 = 0) then
      begin
        R := 20;
        G := 20;
        B := 20;
      end;
      Seed := Seed * 1664525 + 1013904223;
      Noise := Integer(Seed shr 27) - 16;
      R := EnsureRange(R + Noise, 0, 255);
      G := EnsureRange(G + Noise, 0, 255);
      B := EnsureRange(B + Noise, 0, 255);
      Result.Pixels[NativeInt(Y) * AWidth + X] := $FF000000 or Cardinal(R shl 16) or Cardinal(G shl 8) or Cardinal(B);
    end;
end;

end.
