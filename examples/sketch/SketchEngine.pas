unit SketchEngine;

// Framework-independent part of the GUI demos: holds the current image and
// runs sketch/thumbnail on the CPU (1 thread / all cores) or on the GPU through the
// PasToSPIRV shader. Times are measured with QueryPerformanceCounter.

interface

uses
  System.SysUtils,
  SketchImage,
  SketchCPU,
  ThumbnailCPU,
  SketchVulkan;

type
  TSketchMethod = (smCPUSingle, smCPUParallel, smGPU);
  TImageOperation = (soSketch, soThumbnail);

  TSketchResult = record
    Pixels: TArray<Cardinal>;
    Milliseconds: Double;       // QueryPerformanceCounter, as seen by the application
    ShaderMilliseconds: Double; // Vulkan timestamps of the shader passes; NaN if not measured
  end;

  TSketchStatistics = record
    Median: Double;
    Minimum: Double;
    ShaderMedian: Double; // NaN if not measured
    Iterations: Integer;
  end;

  TSketchEngine = class
  private
    FImage: TImagePixels;
    FRadius: Integer;
    FCPU: TSketchCPU;
    FThumbnailCPU: TThumbnailCPU;
    FOperation: TImageOperation;
    FMaxWidth, FMaxHeight, FOutputWidth, FOutputHeight: Integer;
    FGPU: TSketchGPU;
    FGPUError: string;
    FGPUReady: Boolean;
    FSetupMilliseconds: Double;
    FReference: TArray<Cardinal>;
    procedure Execute(AMethod: TSketchMethod; var ATarget: TArray<Cardinal>; out AMilliseconds, AShader: Double);
    function GetGPUAvailable: Boolean;
    function GetGPUName: string;
    procedure Rebuild;
    function GetDescription: string;
  public
    constructor Create(const AShaderFile: string);
    destructor Destroy; override;
    procedure SetImage(const AImage: TImagePixels; ARadius: Integer);
    procedure Configure(AOperation: TImageOperation; AMaxWidth, AMaxHeight: Integer);
    function Run(AMethod: TSketchMethod): TSketchResult;
    function Benchmark(AMethod: TSketchMethod; AIterations: Integer): TSketchStatistics;
    // Single-thread CPU result: the reference for bit-exact checks (cached).
    function Reference: TArray<Cardinal>;
    property Image: TImagePixels read FImage;
    property Radius: Integer read FRadius;
    property Operation: TImageOperation read FOperation;
    property OutputWidth: Integer read FOutputWidth;
    property OutputHeight: Integer read FOutputHeight;
    property Description: string read GetDescription;
    property GPUAvailable: Boolean read GetGPUAvailable;
    property GPUName: string read GetGPUName;
    property GPUError: string read FGPUError;
    // Buffer allocation and command recording for the current size (once per image).
    property SetupMilliseconds: Double read FSetupMilliseconds;
  end;

function SketchMethodName(AMethod: TSketchMethod): string;
function TimerStart: Int64;
function TimerElapsedMs(AStart: Int64): Double;
function MedianOf(AValues: TArray<Double>): Double;
function CountDifferences(const A, B: TArray<Cardinal>): NativeInt;
function ProcessorName: string;
function DefaultShaderFile: string;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.Types,
  System.Math,
  System.IOUtils,
  System.Generics.Collections,
  System.Win.Registry;

var
  Frequency: Int64;

function SketchMethodName(AMethod: TSketchMethod): string;
begin
  case AMethod of
    smCPUSingle: Result := 'CPU, 1 поток';
    smCPUParallel: Result := Format('CPU, %d потоков', [TThread.ProcessorCount]);
  else
    Result := 'GPU, шейдер PasToSPIRV (Vulkan)';
  end;
end;

function TimerStart: Int64;
begin
  QueryPerformanceCounter(Result);
end;

function TimerElapsedMs(AStart: Int64): Double;
var
  Stop: Int64;
begin
  QueryPerformanceCounter(Stop);
  Result := (Stop - AStart) * 1000.0 / Frequency;
end;

function MedianOf(AValues: TArray<Double>): Double;
begin
  if Length(AValues) = 0 then
    Exit(NaN);
  TArray.Sort<Double>(AValues);
  if Odd(Length(AValues)) then
    Result := AValues[Length(AValues) div 2]
  else
    Result := (AValues[Length(AValues) div 2 - 1] + AValues[Length(AValues) div 2]) / 2;
end;

function CountDifferences(const A, B: TArray<Cardinal>): NativeInt;
var
  I: NativeInt;
begin
  if Length(A) <> Length(B) then
    Exit(Max(Length(A), Length(B)));
  Result := 0;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Inc(Result);
end;

function ProcessorName: string;
var
  Registry: TRegistry;
begin
  Result := 'CPU';
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_LOCAL_MACHINE;
    if Registry.OpenKeyReadOnly('HARDWARE\DESCRIPTION\System\CentralProcessor\0') then
      Result := Trim(Registry.ReadString('ProcessorNameString'));
  finally
    Registry.Free;
  end;
end;

function DefaultShaderFile: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)), '..\sketch\sketch.spv'));
  if not TFile.Exists(Result) then
    Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'sketch.spv');
end;

{ TSketchEngine }

constructor TSketchEngine.Create(const AShaderFile: string);
begin
  inherited Create;
  FMaxWidth := 256;
  FMaxHeight := 256;
  try
    FGPU := TSketchGPU.Create(AShaderFile);
  except
    on E: Exception do
    begin
      FGPU := nil;
      FGPUError := E.Message;
    end;
  end;
end;

destructor TSketchEngine.Destroy;
begin
  FCPU.Free;
  FThumbnailCPU.Free;
  FGPU.Free;
  inherited;
end;

function TSketchEngine.GetGPUAvailable: Boolean;
begin
  Result := FGPU <> nil;
end;

function TSketchEngine.GetGPUName: string;
begin
  if FGPU <> nil then
    Result := FGPU.DeviceName
  else
    Result := '';
end;

procedure TSketchEngine.SetImage(const AImage: TImagePixels; ARadius: Integer);
begin
  if (AImage.Width < 1) or (AImage.Height < 1) or
    (Int64(AImage.Width) * AImage.Height <> Length(AImage.Pixels)) then
    raise EArgumentException.Create('Invalid source image');
  FImage := AImage;
  FRadius := ARadius;
  Rebuild;
end;

procedure TSketchEngine.Configure(AOperation: TImageOperation; AMaxWidth, AMaxHeight: Integer);
begin
  if (FOperation = AOperation) and (FMaxWidth = AMaxWidth) and (FMaxHeight = AMaxHeight) then
    Exit;
  if (AMaxWidth < 1) or (AMaxHeight < 1) or (AMaxWidth > 65535) or (AMaxHeight > 65535) then
    raise EArgumentException.Create('Thumbnail bounds must be in 1..65535');
  FOperation := AOperation;
  FMaxWidth := AMaxWidth;
  FMaxHeight := AMaxHeight;
  if Length(FImage.Pixels) > 0 then
    Rebuild;
end;

function TSketchEngine.GetDescription: string;
begin
  if FOperation = soThumbnail then
    Result := Format('Миниатюра %d x %d', [FOutputWidth, FOutputHeight])
  else
    Result := Format('Эскиз, радиус %d', [FRadius]);
end;

procedure TSketchEngine.Rebuild;
var
  Size: TPoint;
begin
  FreeAndNil(FCPU);
  FreeAndNil(FThumbnailCPU);
  FReference := nil;
  FGPUReady := False;
  FSetupMilliseconds := 0;
  FOutputWidth := FImage.Width;
  FOutputHeight := FImage.Height;
  if FOperation = soThumbnail then
  begin
    Size := ThumbnailSize(FImage.Width, FImage.Height, FMaxWidth, FMaxHeight);
    FOutputWidth := Size.X;
    FOutputHeight := Size.Y;
    FThumbnailCPU := TThumbnailCPU.Create(FImage.Width, FImage.Height, Size.X, Size.Y);
  end
  else
    FCPU := TSketchCPU.Create(FImage.Width, FImage.Height, FRadius);
end;

procedure TSketchEngine.Execute(AMethod: TSketchMethod; var ATarget: TArray<Cardinal>;
  out AMilliseconds, AShader: Double);
var
  Start: Int64;
  Timings: TGPUTimings;
begin
  if (FCPU = nil) and (FThumbnailCPU = nil) then
    raise EInvalidOpException.Create('No image loaded');
  if Length(ATarget) <> NativeInt(FOutputWidth) * FOutputHeight then
    SetLength(ATarget, NativeInt(FOutputWidth) * FOutputHeight);
  AShader := NaN;
  case AMethod of
    smCPUSingle:
      begin
        Start := TimerStart;
        if FOperation = soThumbnail then
          FThumbnailCPU.RunSingle(FImage.Pixels, ATarget)
        else
          FCPU.RunSingle(FImage.Pixels, ATarget);
        AMilliseconds := TimerElapsedMs(Start);
      end;
    smCPUParallel:
      begin
        Start := TimerStart;
        if FOperation = soThumbnail then
          FThumbnailCPU.RunParallel(FImage.Pixels, ATarget)
        else
          FCPU.RunParallel(FImage.Pixels, ATarget);
        AMilliseconds := TimerElapsedMs(Start);
      end;
    smGPU:
      begin
        if FGPU = nil then
          raise EInvalidOpException.Create('GPU недоступен: ' + FGPUError);
        if not FGPUReady then
        begin
          Start := TimerStart;
          if FOperation = soThumbnail then
            FGPU.PrepareThumbnail(FImage.Width, FImage.Height, FOutputWidth, FOutputHeight)
          else
            FGPU.Prepare(FImage.Width, FImage.Height, FRadius);
          FSetupMilliseconds := TimerElapsedMs(Start);
          FGPUReady := True;
        end;
        Start := TimerStart;
        Timings := FGPU.Run(FImage.Pixels, ATarget);
        AMilliseconds := TimerElapsedMs(Start);
        if Timings.HasTimestamps then
          AShader := Timings.Kernels;
      end;
  end;
end;

function TSketchEngine.Run(AMethod: TSketchMethod): TSketchResult;
begin
  Execute(AMethod, Result.Pixels, Result.Milliseconds, Result.ShaderMilliseconds);
  if AMethod = smCPUSingle then
    FReference := Copy(Result.Pixels);
end;

function TSketchEngine.Benchmark(AMethod: TSketchMethod; AIterations: Integer): TSketchStatistics;
var
  Target: TArray<Cardinal>;
  Times, Shader: TArray<Double>;
  Milliseconds, ShaderMs: Double;
  I: Integer;
begin
  if AIterations < 1 then
    raise EArgumentException.Create('At least one benchmark iteration is required');
  Execute(AMethod, Target, Milliseconds, ShaderMs); // warm-up
  SetLength(Times, AIterations);
  Shader := nil;
  for I := 0 to AIterations - 1 do
  begin
    Execute(AMethod, Target, Times[I], ShaderMs);
    if not IsNan(ShaderMs) then
      Shader := Shader + [ShaderMs];
  end;
  Result.Median := MedianOf(Times);
  Result.Minimum := MinValue(Times);
  Result.ShaderMedian := MedianOf(Shader);
  Result.Iterations := AIterations;
end;

function TSketchEngine.Reference: TArray<Cardinal>;
var
  Milliseconds, Shader: Double;
begin
  if FReference = nil then
    Execute(smCPUSingle, FReference, Milliseconds, Shader);
  Result := FReference;
end;

initialization
  QueryPerformanceFrequency(Frequency);

end.
