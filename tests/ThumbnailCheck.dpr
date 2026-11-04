program ThumbnailCheck;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Types,
  System.Math,
  SketchShaderBindings in '..\build\sketch\SketchShaderBindings.pas',
  SketchImage in '..\examples\sketch\SketchImage.pas',
  SketchCPU in '..\examples\sketch\SketchCPU.pas',
  ThumbnailCPU in '..\examples\sketch\ThumbnailCPU.pas',
  SketchVulkan in '..\examples\sketch\SketchVulkan.pas',
  SketchEngine in '..\examples\sketch\SketchEngine.pas';

procedure Require(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    raise Exception.Create(AMessage);
end;

// Independent reference, no shared .inc. Filter channels separately using Int64
// coverage weights, quantizing after each axis as specified for this example.
function Oracle(const AImage: TImagePixels; W, H: Integer): TArray<Cardinal>;
var
  Horizontal: TArray<Cardinal>;
  X, Y, C, I, Pass, SourceCount, TargetCount, Position, Taps: Integer;
  Sum, Weight, First, Last, Value, Pixel, Alpha: Int64;
begin
  if (W = AImage.Width) and (H = AImage.Height) then
    Exit(Copy(AImage.Pixels));
  SetLength(Horizontal, W * AImage.Height);
  SetLength(Result, W * H);
  for Pass := 0 to 1 do
  begin
    if Pass = 0 then
    begin
      SourceCount := AImage.Width;
      TargetCount := W;
      Taps := AImage.Height;
    end
    else
    begin
      SourceCount := AImage.Height;
      TargetCount := H;
      Taps := H;
    end;
    for Y := 0 to Taps - 1 do
      for X := 0 to W - 1 do
      begin
        if Pass = 0 then Position := X else Position := Y;
        First := Int64(Position) * SourceCount;
        Last := Int64(Position + 1) * SourceCount;
        Pixel := 0;
        for C := 0 to 3 do
        begin
          Sum := 0;
          for I := First div TargetCount to (Last - 1) div TargetCount do
          begin
            Weight := Min(Last, Int64(I + 1) * TargetCount) - Max(First, Int64(I) * TargetCount);
            if Pass = 0 then
            begin
              Value := AImage.Pixels[Y * AImage.Width + I];
              Alpha := Value shr 24;
              Value := (Value shr (8 * C)) and 255;
              if C <> 3 then Value := (Value * Alpha + 127) div 255;
            end
            else
              Value := (Horizontal[I * W + X] shr (8 * C)) and 255;
            Inc(Sum, Value * Weight);
          end;
          Value := (Sum + SourceCount div 2) div SourceCount;
          Pixel := Pixel or (Value shl (8 * C));
        end;
        if Pass = 0 then
          Horizontal[Y * W + X] := Pixel
        else
        begin
          Alpha := Pixel shr 24;
          Result[Y * W + X] := Cardinal(Alpha shl 24);
          if Alpha > 0 then
            for C := 0 to 2 do
            begin
              Value := Min(Int64(255), (((Pixel shr (8 * C)) and 255) * 255 + Alpha div 2) div Alpha);
              Result[Y * W + X] := Result[Y * W + X] or Cardinal(Value shl (8 * C));
            end;
        end;
      end;
  end;
end;

procedure Run;
const
  Cases: array[0..13] of record W, H, MaxW, MaxH: Integer; end = (
    (W: 2; H: 2; MaxW: 1; MaxH: 1),
    (W: 3; H: 1; MaxW: 2; MaxH: 1),
    (W: 97; H: 61; MaxW: 37; MaxH: 29),
    (W: 61; H: 97; MaxW: 29; MaxH: 37),
    (W: 1; H: 97; MaxW: 128; MaxH: 17),
    (W: 97; H: 1; MaxW: 17; MaxH: 128),
    (W: 1; H: 1; MaxW: 256; MaxH: 256),
    (W: 7; H: 5; MaxW: 256; MaxH: 256),
    (W: 31; H: 23; MaxW: 1; MaxH: 1),
    (W: 65535; H: 1; MaxW: 1; MaxH: 1),
    (W: 1; H: 65535; MaxW: 1; MaxH: 1),
    (W: 33; H: 17; MaxW: 33; MaxH: 8),
    (W: 65535; H: 1; MaxW: 65534; MaxH: 1),
    (W: 1; H: 65535; MaxW: 1; MaxH: 65534));
var
  Engine: TSketchEngine;
  Image: TImagePixels;
  Expected, Original: TArray<Cardinal>;
  Actual: TSketchResult;
  Method: TSketchMethod;
  Size: TPoint;
  I, J: Integer;
  Seed: Cardinal;
  GPU: Boolean;
begin
  PTS_ValidateLayouts;
  GPU := (ParamCount = 1) and (ParamStr(1) = '--gpu');
  Engine := TSketchEngine.Create(DefaultShaderFile);
  try
    Require(not GPU or Engine.GPUAvailable, 'GPU required: ' + Engine.GPUError);
    Seed := 12345;
    for I := 0 to High(Cases) do
    begin
      Image.Width := Cases[I].W;
      Image.Height := Cases[I].H;
      SetLength(Image.Pixels, Image.Width * Image.Height);
      for J := 0 to High(Image.Pixels) do
      begin
        Seed := Seed xor (Seed shl 13);
        Seed := Seed xor (Seed shr 17);
        Seed := Seed xor (Seed shl 5);
        Image.Pixels[J] := Seed;
      end;
      if I = 0 then Image.Pixels := [$FFFFFFFF, $FF000000, $FF000000, $FFFFFFFF];
      if I = 1 then Image.Pixels := [$FF000000, $FFFFFFFF, $FF000000];
      Original := Copy(Image.Pixels);
      Size := ThumbnailSize(Image.Width, Image.Height, Cases[I].MaxW, Cases[I].MaxH);
      Require((Size.X <= Image.Width) and (Size.Y <= Image.Height) and
        (Size.X <= Cases[I].MaxW) and (Size.Y <= Cases[I].MaxH), 'Invalid aspect-fit bounds');
      Expected := Oracle(Image, Size.X, Size.Y);
      if I = 0 then Require(Expected[0] = $FF808080, 'Checkerboard must average to gray');
      if I = 1 then Require((Length(Expected) = 2) and (Expected[0] = $FF555555) and
        (Expected[1] = $FF555555), 'Fractional coverage 3 -> 2');
      Engine.SetImage(Image, 1);
      Engine.Configure(soThumbnail, Cases[I].MaxW, Cases[I].MaxH);
      Require((Engine.OutputWidth = Size.X) and (Engine.OutputHeight = Size.Y), 'Engine output dimensions');
      for Method := Low(TSketchMethod) to High(TSketchMethod) do
      begin
        if (Method = smGPU) and not GPU then Continue;
        Actual := Engine.Run(Method);
        Require(CountDifferences(Expected, Actual.Pixels) = 0, Format('Thumbnail case %d method %d differs', [I, Ord(Method)]));
      end;
      Require(CountDifferences(Image.Pixels, Original) = 0, 'Input was modified');
    end;
    Image.Width := 2;
    Image.Height := 1;
    Image.Pixels := [$FFFF0000, $000000FF]; // invisible blue must not contaminate red
    Engine.SetImage(Image, 1);
    Engine.Configure(soThumbnail, 1, 1);
    Actual := Engine.Run(smCPUSingle);
    Require(Actual.Pixels[0] = $80FF0000, 'Transparent-edge premultiplication');
    if GPU then
    begin
      Actual := Engine.Run(smGPU);
      Require(Actual.Pixels[0] = $80FF0000, 'GPU transparent-edge premultiplication');
    end;
    Engine.Configure(soThumbnail, 256, 256);
    Require(CountDifferences(Engine.Reference, Image.Pixels) = 0, 'Bounds change must invalidate reference cache');
    if GPU then
    begin
      Actual := Engine.Run(smGPU);
      Require(CountDifferences(Actual.Pixels, Image.Pixels) = 0, 'GPU bounds change / no-upscale identity');
    end;
    // Switch operation, then return to thumbnail on the same GPU host.
    Engine.Configure(soSketch, 256, 256);
    Actual := Engine.Run(smCPUSingle);
    Expected := Actual.Pixels;
    if GPU then
    begin
      Actual := Engine.Run(smGPU);
      Require(CountDifferences(Expected, Actual.Pixels) = 0, 'Sketch after thumbnail');
    end;
    Engine.Configure(soThumbnail, 1, 1);
    Actual := Engine.Run(smCPUSingle);
    Require(Actual.Pixels[0] = $80FF0000, 'Thumbnail after sketch');
    try
      ThumbnailSize(0, 1, 128, 128);
      raise Exception.Create('Accepted zero input width');
    except
      on E: EArgumentException do ;
    end;
    try
      ValidateThumbnailSizes(1, 1, 2, 1);
      raise Exception.Create('Accepted upscaling');
    except
      on E: EArgumentException do ;
    end;
    try
      ThumbnailSize(65536, 1, 128, 128);
      raise Exception.Create('Accepted source dimension >65535');
    except
      on E: EArgumentException do ;
    end;
    try
      ThumbnailSize(1, 1, 0, 128);
      raise Exception.Create('Accepted zero thumbnail bound');
    except
      on E: EArgumentException do ;
    end;
    if GPU then Writeln('PASS: thumbnails CPU/GPU bit-identical, 14 sizes, alpha, fractional coverage, mode switches.')
    else Writeln('PASS: thumbnails CPU oracle, parallel, aspect fit, no upscale, alpha, fractional coverage.');
  finally
    Engine.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.Message);
      ExitCode := 2;
    end;
  end;
end.
