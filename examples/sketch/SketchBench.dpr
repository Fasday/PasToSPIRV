program SketchBench;

// Pencil-sketch filter and benchmark: Delphi CPU (1 thread and all cores)
// versus a PasToSPIRV compute shader on Vulkan. Same integer algorithm on both
// sides, so the GPU output is checked bit-for-bit against the CPU output.
//
//   SketchBench [image] [--radius N] [--sizes WxH,...] [--iterations N]
//               [--cpu-iterations N] [--out DIR] [--shader FILE] [--cpu-only]

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  Winapi.ActiveX,
  System.SysUtils,
  System.Classes,
  System.Math,
  System.IOUtils,
  System.Generics.Collections,
  System.Win.Registry,
  SketchShaderBindings in '..\..\build\sketch\SketchShaderBindings.pas',
  SketchImage in 'SketchImage.pas',
  SketchCPU in 'SketchCPU.pas',
  SketchVulkan in 'SketchVulkan.pas';

type
  TOptions = record
    ImageFile: string;
    Radius: Integer;
    Sizes: TArray<TPoint>;
    GPUIterations: Integer;
    CPUIterations: Integer;
    OutputDirectory: string;
    ShaderFile: string;
    CPUOnly: Boolean;
  end;

  TMeasurement = record
    Name: string;
    Median: Double;
    Minimum: Double;
  end;

var
  Frequency: Int64;
  Report: TStringList;

function StartTimer: Int64;
begin
  QueryPerformanceCounter(Result);
end;

function ElapsedMs(AStart: Int64): Double;
var
  Stop: Int64;
begin
  QueryPerformanceCounter(Stop);
  Result := (Stop - AStart) * 1000.0 / Frequency;
end;

function Median(AValues: TArray<Double>): Double;
begin
  TArray.Sort<Double>(AValues);
  if Length(AValues) mod 2 = 1 then
    Result := AValues[Length(AValues) div 2]
  else
    Result := (AValues[Length(AValues) div 2 - 1] + AValues[Length(AValues) div 2]) / 2;
end;

function Measure(const AName: string; AIterations: Integer; const AAction: TProc): TMeasurement;
var
  Samples: TArray<Double>;
  I: Integer;
  Start: Int64;
begin
  AAction; // warm-up: page-in, caches, thread pool, driver
  SetLength(Samples, AIterations);
  for I := 0 to AIterations - 1 do
  begin
    Start := StartTimer;
    AAction;
    Samples[I] := ElapsedMs(Start);
  end;
  Result.Name := AName;
  Result.Median := Median(Samples);
  Result.Minimum := MinValue(Samples);
end;

function DifferentPixels(const A, B: TArray<Cardinal>): NativeInt;
var
  I: NativeInt;
begin
  Result := 0;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Inc(Result);
end;

function ProcessorName: string;
var
  Registry: TRegistry;
begin
  Result := 'unknown CPU';
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_LOCAL_MACHINE;
    if Registry.OpenKeyReadOnly('HARDWARE\DESCRIPTION\System\CentralProcessor\0') then
      Result := Trim(Registry.ReadString('ProcessorNameString'));
  finally
    Registry.Free;
  end;
end;

function ParseSizes(const AText: string): TArray<TPoint>;
var
  Item: string;
  Parts: TArray<string>;
  Size: TPoint;
begin
  Result := nil;
  for Item in AText.Split([',']) do
  begin
    Parts := LowerCase(Trim(Item)).Split(['x']);
    if (Length(Parts) <> 2) or not TryStrToInt(Parts[0], Size.X) or not TryStrToInt(Parts[1], Size.Y) or
      (Size.X < 1) or (Size.Y < 1) or (Int64(Size.X) * Size.Y > 64 * 1024 * 1024) then
      raise EArgumentException.Create('Sizes must look like 1920x1080,3840x2160 (up to 64 Mi pixels)');
    Result := Result + [Size];
  end;
end;

function ParseOptions: TOptions;
var
  I: Integer;
  Argument: string;
  function Value: string;
  begin
    Inc(I);
    if I > ParamCount then
      raise EArgumentException.Create('Missing value after ' + Argument);
    Result := ParamStr(I);
  end;
begin
  Result := Default(TOptions);
  Result.Radius := 12;
  Result.Sizes := ParseSizes('1280x720,1920x1080,3840x2160');
  Result.GPUIterations := 20;
  Result.CPUIterations := 3;
  Result.OutputDirectory := TPath.Combine(ExtractFilePath(ParamStr(0)), '..\sketch\out');
  Result.ShaderFile := TPath.Combine(ExtractFilePath(ParamStr(0)), '..\sketch\sketch.spv');
  if not TFile.Exists(Result.ShaderFile) then
    Result.ShaderFile := TPath.Combine(ExtractFilePath(ParamStr(0)), 'sketch.spv');
  I := 1;
  while I <= ParamCount do
  begin
    Argument := ParamStr(I);
    if Argument = '--radius' then Result.Radius := StrToInt(Value)
    else if Argument = '--sizes' then Result.Sizes := ParseSizes(Value)
    else if Argument = '--iterations' then Result.GPUIterations := StrToInt(Value)
    else if Argument = '--cpu-iterations' then Result.CPUIterations := StrToInt(Value)
    else if Argument = '--out' then Result.OutputDirectory := Value
    else if Argument = '--shader' then Result.ShaderFile := Value
    else if Argument = '--cpu-only' then Result.CPUOnly := True
    else if (Argument <> '') and (Argument[1] = '-') then
      raise EArgumentException.Create('Unknown option ' + Argument)
    else if Result.ImageFile = '' then Result.ImageFile := Argument
    else raise EArgumentException.Create('Only one input image is accepted');
    Inc(I);
  end;
  if (Result.Radius < MinSketchRadius) or (Result.Radius > MaxSketchRadius) then
    raise EArgumentException.CreateFmt('--radius must be in %d..%d', [MinSketchRadius, MaxSketchRadius]);
  if (Result.GPUIterations < 1) or (Result.GPUIterations > 1000) or
    (Result.CPUIterations < 1) or (Result.CPUIterations > 100) then
    raise EArgumentException.Create('Iteration counts must be in 1..1000 (GPU) and 1..100 (CPU)');
  Result.OutputDirectory := TPath.GetFullPath(Result.OutputDirectory);
  Result.ShaderFile := TPath.GetFullPath(Result.ShaderFile);
end;

procedure Line(const AText: string = '');
begin
  Writeln(AText);
end;

procedure PrintRow(const AMeasurement: TMeasurement; APixels: Int64; ABaseline: Double);
begin
  Line(Format('  %-44s %10.2f %10.2f %10.1f %9.1fx', [AMeasurement.Name, AMeasurement.Median,
    AMeasurement.Minimum, APixels / 1E6 / (AMeasurement.Median / 1000), ABaseline / AMeasurement.Median]));
end;

procedure AddCsv(const AImage: TImagePixels; ARadius: Integer; const AMeasurement: TMeasurement);
begin
  Report.Add(Format('%d,%d,%d,"%s",%.4f,%.4f', [AImage.Width, AImage.Height, ARadius,
    AMeasurement.Name, AMeasurement.Median, AMeasurement.Minimum], TFormatSettings.Invariant));
end;

function BenchmarkImage(const AImage: TImagePixels; const AOptions: TOptions; AGPU: TSketchGPU;
  ASaveImages: Boolean): Boolean;
var
  CPU: TSketchCPU;
  Single, Parallel, GPU: TArray<Cardinal>;
  Pixels: Int64;
  SingleTime, ParallelTime, GPUTime, KernelTime: TMeasurement;
  Timings: TGPUTimings;
  Uploads, Kernels, Downloads: TArray<Double>;
  PrepareTime: Double;
  Start: Int64;
  Output: TImagePixels;
  Mismatch: NativeInt;
begin
  Result := True;
  Pixels := Int64(AImage.Width) * AImage.Height;
  Line;
  Line(Format('Image %dx%d (%.2f MP), radius %d', [AImage.Width, AImage.Height, Pixels / 1E6, AOptions.Radius]));
  Line(Format('  %-44s %10s %10s %10s %10s', ['Method', 'median ms', 'min ms', 'MP/s', 'vs 1 CPU']));
  SetLength(Single, Pixels);
  SetLength(Parallel, Pixels);
  CPU := TSketchCPU.Create(AImage.Width, AImage.Height, AOptions.Radius);
  try
    SingleTime := Measure('CPU, 1 thread (Delphi)', AOptions.CPUIterations,
      procedure begin CPU.RunSingle(AImage.Pixels, Single); end);
    PrintRow(SingleTime, Pixels, SingleTime.Median);
    AddCsv(AImage, AOptions.Radius, SingleTime);
    ParallelTime := Measure(Format('CPU, %d threads (TParallel.For)', [TThread.ProcessorCount]),
      Max(AOptions.CPUIterations, 5), procedure begin CPU.RunParallel(AImage.Pixels, Parallel); end);
    PrintRow(ParallelTime, Pixels, SingleTime.Median);
    AddCsv(AImage, AOptions.Radius, ParallelTime);
  finally
    CPU.Free;
  end;
  Mismatch := DifferentPixels(Single, Parallel);
  if Mismatch <> 0 then
  begin
    Line(Format('  ERROR: parallel CPU differs from single-thread CPU in %d pixels', [Mismatch]));
    Result := False;
  end;
  if AGPU <> nil then
  begin
    SetLength(GPU, Pixels);
    Start := StartTimer;
    AGPU.Prepare(AImage.Width, AImage.Height, AOptions.Radius);
    PrepareTime := ElapsedMs(Start);
    Uploads := nil;
    Kernels := nil;
    Downloads := nil;
    GPUTime := Measure('GPU, end-to-end (copy in + 3 passes + out)', AOptions.GPUIterations,
      procedure
      begin
        Timings := AGPU.Run(AImage.Pixels, GPU);
        if Timings.HasTimestamps then
        begin
          Uploads := Uploads + [Timings.Upload];
          Kernels := Kernels + [Timings.Kernels];
          Downloads := Downloads + [Timings.Download];
        end;
      end);
    PrintRow(GPUTime, Pixels, SingleTime.Median);
    AddCsv(AImage, AOptions.Radius, GPUTime);
    if Length(Kernels) > 0 then
    begin
      // Drop the warm-up sample recorded by Measure.
      Delete(Uploads, 0, 1);
      Delete(Kernels, 0, 1);
      Delete(Downloads, 0, 1);
      KernelTime.Name := 'GPU, shader only (Vulkan timestamps)';
      KernelTime.Median := Median(Kernels);
      KernelTime.Minimum := MinValue(Kernels);
      PrintRow(KernelTime, Pixels, SingleTime.Median);
      AddCsv(AImage, AOptions.Radius, KernelTime);
      Line(Format('    GPU timestamps, median ms: upload %.2f, shader %.2f, download %.2f; ' +
        'setup for this size %.1f ms (not timed above)',
        [Median(Uploads), KernelTime.Median, Median(Downloads), PrepareTime]));
    end;
    Mismatch := DifferentPixels(Single, GPU);
    if Mismatch = 0 then
      Line('  Check: GPU result is bit-identical to the CPU result')
    else
    begin
      Line(Format('  ERROR: GPU result differs from CPU in %d of %d pixels', [Mismatch, Pixels]));
      Result := False;
    end;
  end;
  if ASaveImages then
  begin
    ForceDirectories(AOptions.OutputDirectory);
    SavePng(TPath.Combine(AOptions.OutputDirectory, 'source.png'), AImage);
    Output.Width := AImage.Width;
    Output.Height := AImage.Height;
    Output.Pixels := Single;
    SavePng(TPath.Combine(AOptions.OutputDirectory, 'sketch_cpu.png'), Output);
    if AGPU <> nil then
    begin
      Output.Pixels := GPU;
      SavePng(TPath.Combine(AOptions.OutputDirectory, 'sketch_gpu.png'), Output);
    end;
  end;
end;

function Run: Integer;
var
  Options: TOptions;
  GPU: TSketchGPU;
  Images: TList<TImagePixels>;
  Image: TImagePixels;
  Size: TPoint;
  Start: Int64;
  I: Integer;
  AllCorrect: Boolean;
begin
  Result := 0;
  QueryPerformanceFrequency(Frequency);
  Options := ParseOptions;
  // Checks the generated std430 bindings against the Delphi compiler's layout.
  PTS_ValidateLayouts;
  Report := TStringList.Create;
  Images := TList<TImagePixels>.Create;
  GPU := nil;
  try
    Report.Add('width,height,radius,method,median_ms,min_ms');
    Line('PasToSPIRV pencil-sketch benchmark');
    Line('  CPU:   ' + ProcessorName + Format(', %d logical processors', [TThread.ProcessorCount]));
    Line(Format('  Timer: QueryPerformanceCounter, %d Hz; GPU detail from Vulkan timestamps', [Frequency]));
    if not Options.CPUOnly then
    begin
      try
        Start := StartTimer;
        GPU := TSketchGPU.Create(Options.ShaderFile);
        Line(Format('  GPU:   %s (Vulkan init + pipeline: %.1f ms, once)', [GPU.DeviceName, ElapsedMs(Start)]));
        Line('  Shader: ' + Options.ShaderFile);
      except
        on E: Exception do
        begin
          Line('  GPU:   unavailable - ' + E.Message);
          GPU := nil;
        end;
      end;
    end
    else
      Line('  GPU:   skipped (--cpu-only)');
    if Options.ImageFile <> '' then
    begin
      Image := LoadImage(Options.ImageFile);
      Images.Add(Image);
      Line('  Input: ' + Options.ImageFile);
    end
    else
    begin
      for Size in Options.Sizes do
        Images.Add(SyntheticImage(Size.X, Size.Y));
      Line('  Input: synthetic test image');
    end;
    AllCorrect := True;
    for I := 0 to Images.Count - 1 do
      // Images are written for the largest synthetic size or the user's file.
      AllCorrect := BenchmarkImage(Images[I], Options, GPU, I = Images.Count - 1) and AllCorrect;
    ForceDirectories(Options.OutputDirectory);
    Report.SaveToFile(TPath.Combine(Options.OutputDirectory, 'benchmark.csv'), TEncoding.UTF8);
    Line;
    Line('Images and benchmark.csv: ' + Options.OutputDirectory);
    Line('Notes: times exclude PNG decode/encode; the GPU end-to-end time includes host<->GPU copies;');
    Line('       the CPU code is plain Delphi (no SIMD intrinsics); results depend on hardware and drivers.');
    if not AllCorrect then
      Result := 3;
  finally
    GPU.Free;
    Images.Free;
    Report.Free;
  end;
end;

begin
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    try
      ExitCode := Run;
    except
      on E: Exception do
      begin
        Writeln(ErrOutput, 'error: ', E.Message);
        ExitCode := 2;
      end;
    end;
  finally
    CoUninitialize;
  end;
end.
