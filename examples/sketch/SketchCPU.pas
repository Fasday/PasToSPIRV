unit SketchCPU;

// CPU implementation of the same pencil-sketch algorithm as sketch.pas.
// The per-pixel math comes from the shared SketchMath.inc, so the result is
// bit-identical to the GPU path. Loops are arranged for the CPU (padded rows,
// row-wise vertical accumulation, precomputed weights), not translated 1:1.

{$Q-}
{$R-}
{$POINTERMATH ON}

interface

const
  MinSketchRadius = 1;
  MaxSketchRadius = 32;

type
  TSketchCPU = class
  private
    FWidth: Integer;
    FHeight: Integer;
    FRadius: Integer;
    FGray: TArray<Cardinal>;
    FHorizontal: TArray<Cardinal>;
    FWeights: TArray<Cardinal>;
    procedure GrayRows(ASource: PCardinal; AFirst, ALast: Integer);
    procedure HorizontalRows(AFirst, ALast: Integer; var AInverted: TArray<Cardinal>);
    procedure VerticalRows(ATarget: PCardinal; AFirst, ALast: Integer; var AAccumulator: TArray<Cardinal>);
  public
    constructor Create(AWidth, AHeight, ARadius: Integer);
    // One thread: the reference implementation.
    procedure RunSingle(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>);
    // All logical processors: bands of rows on the Delphi RTL thread pool.
    procedure RunParallel(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>);
  end;

implementation

uses
  System.SysUtils,
  System.Math,
  System.Threading;

{$I 'SketchMath.inc'}

const
  BandRows = 16;

constructor TSketchCPU.Create(AWidth, AHeight, ARadius: Integer);
var
  Tap: Integer;
begin
  inherited Create;
  if (ARadius < MinSketchRadius) or (ARadius > MaxSketchRadius) then
    raise EArgumentOutOfRangeException.CreateFmt('Radius must be in %d..%d', [MinSketchRadius, MaxSketchRadius]);
  FWidth := AWidth;
  FHeight := AHeight;
  FRadius := ARadius;
  // Scratch buffers are allocated once, outside the timed region (as on the GPU).
  SetLength(FGray, NativeInt(AWidth) * AHeight);
  SetLength(FHorizontal, NativeInt(AWidth) * AHeight);
  SetLength(FWeights, 2 * ARadius + 1);
  for Tap := 0 to 2 * ARadius do
    FWeights[Tap] := SketchWeight(Tap, ARadius);
end;

procedure TSketchCPU.GrayRows(ASource: PCardinal; AFirst, ALast: Integer);
var
  Index, Stop: NativeInt;
begin
  Index := NativeInt(AFirst) * FWidth;
  Stop := NativeInt(ALast + 1) * FWidth;
  while Index < Stop do
  begin
    FGray[Index] := SketchLuma(ASource[Index]);
    Inc(Index);
  end;
end;

procedure TSketchCPU.HorizontalRows(AFirst, ALast: Integer; var AInverted: TArray<Cardinal>);
var
  Y, X, Tap, Taps, Padded: Integer;
  Row, Output, Window, Weights: PCardinal;
  Sum: Cardinal;
begin
  Taps := 2 * FRadius;
  Padded := FWidth + Taps;
  if Length(AInverted) < Padded then
    SetLength(AInverted, Padded);
  Weights := @FWeights[0];
  for Y := AFirst to ALast do
  begin
    Row := @FGray[NativeInt(Y) * FWidth];
    // Padded index P holds column P - Radius clamped, so tap T of X is P = X + T.
    for X := 0 to Padded - 1 do
      AInverted[X] := 255 - Row[SketchSample(X, 0, FRadius, FWidth)];
    Output := @FHorizontal[NativeInt(Y) * FWidth];
    for X := 0 to FWidth - 1 do
    begin
      Window := @AInverted[X];
      Sum := 0;
      for Tap := 0 to Taps do
        Inc(Sum, Weights[Tap] * Window[Tap]);
      Output[X] := Sum;
    end;
  end;
end;

procedure TSketchCPU.VerticalRows(ATarget: PCardinal; AFirst, ALast: Integer;
  var AAccumulator: TArray<Cardinal>);
var
  Y, X, Tap: Integer;
  Weight: Cardinal;
  Accumulator, Column: PCardinal;
  Index: NativeInt;
begin
  if Length(AAccumulator) < FWidth then
    SetLength(AAccumulator, FWidth);
  Accumulator := @AAccumulator[0];
  for Y := AFirst to ALast do
  begin
    FillChar(Accumulator^, FWidth * SizeOf(Cardinal), 0);
    // Row-wise accumulation keeps memory access sequential.
    for Tap := 0 to 2 * FRadius do
    begin
      Weight := FWeights[Tap];
      Column := @FHorizontal[NativeInt(SketchSample(Y, Tap, FRadius, FHeight)) * FWidth];
      for X := 0 to FWidth - 1 do
        Inc(Accumulator[X], Weight * Column[X]);
    end;
    Index := NativeInt(Y) * FWidth;
    for X := 0 to FWidth - 1 do
      ATarget[Index + X] := SketchPack(SketchDodge(FGray[Index + X],
        SketchNormalize(Accumulator[X], FRadius)));
  end;
end;

procedure TSketchCPU.RunSingle(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>);
var
  Inverted, Accumulator: TArray<Cardinal>;
begin
  GrayRows(@ASource[0], 0, FHeight - 1);
  HorizontalRows(0, FHeight - 1, Inverted);
  VerticalRows(@ATarget[0], 0, FHeight - 1, Accumulator);
end;

procedure TSketchCPU.RunParallel(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>);
var
  Bands: Integer;
  Source, Target: PCardinal;
begin
  Bands := (FHeight + BandRows - 1) div BandRows;
  Source := @ASource[0];
  Target := @ATarget[0];
  // Each pass completes before the next starts: the CPU analogue of a barrier.
  TParallel.For(0, Bands - 1,
    procedure(Band: Integer)
    begin
      GrayRows(Source, Band * BandRows, Min(FHeight, (Band + 1) * BandRows) - 1);
    end);
  TParallel.For(0, Bands - 1,
    procedure(Band: Integer)
    var
      Inverted: TArray<Cardinal>;
    begin
      HorizontalRows(Band * BandRows, Min(FHeight, (Band + 1) * BandRows) - 1, Inverted);
    end);
  TParallel.For(0, Bands - 1,
    procedure(Band: Integer)
    var
      Accumulator: TArray<Cardinal>;
    begin
      VerticalRows(Target, Band * BandRows, Min(FHeight, (Band + 1) * BandRows) - 1, Accumulator);
    end);
end;

end.
