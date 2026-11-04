unit MainFMX;

// FireMonkey demo: pencil sketch / thumbnails on CPU (1 thread / all cores) or GPU
// through PasToSPIRV, plus stock TFilterPencilStroke / TBitmap.CreateThumbnail.
// The built-in filter is a different, simpler effect (a Laplacian of 5 samples)
// rendered by FMX on its own GPU context, so it is timed but not compared bit-for-bit.

interface

uses
  System.SysUtils,
  System.Types,
  System.UITypes,
  System.Classes,
  System.Math,
  FMX.Types,
  FMX.Controls,
  FMX.Forms,
  FMX.Graphics,
  FMX.Dialogs,
  FMX.StdCtrls,
  FMX.Controls.Presentation,
  FMX.Layouts,
  FMX.Objects,
  FMX.ListBox,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.ScrollBox,
  FMX.Filter.Effects,
  SketchImage,
  SketchEngine;

type
  TMainForm = class(TForm)
    TopBar: TToolBar;
    OpenButton: TButton;
    TestButton: TButton;
    SizeCombo: TComboBox;
    RadiusLabel: TLabel;
    RadiusTrack: TTrackBar;
    MethodCombo: TComboBox;
    RunButton: TButton;
    BenchButton: TButton;
    SaveButton: TButton;
    OptionsBar: TToolBar;
    OperationCombo: TComboBox;
    ThumbnailCombo: TComboBox;
    ThumbnailLabel: TLabel;
    ThumbnailHint: TLabel;
    ImagesLayout: TLayout;
    SourceLayout: TLayout;
    SourceCaption: TLabel;
    SourceImage: TImage;
    Splitter: TSplitter;
    ResultLayout: TLayout;
    ResultCaption: TLabel;
    ResultImage: TImage;
    LogMemo: TMemo;
    StatusBar: TStatusBar;
    StatusLabel: TLabel;
    OpenDialog: TOpenDialog;
    SaveDialog: TSaveDialog;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure ImagesLayoutResized(Sender: TObject);
    procedure OpenButtonClick(Sender: TObject);
    procedure TestButtonClick(Sender: TObject);
    procedure RadiusTrackChange(Sender: TObject);
    procedure OperationChanged(Sender: TObject);
    procedure RunButtonClick(Sender: TObject);
    procedure BenchButtonClick(Sender: TObject);
    procedure SaveButtonClick(Sender: TObject);
  private
    FEngine: TSketchEngine;
    FPencil: TFilterPencilStroke;
    FSourceBitmap: TBitmap;
    FStockThumbnail: TBitmap;
    FStockPixels: TImagePixels;
    FResult: TImagePixels;
    FHasResult: Boolean;
    FBusy: Boolean;
    FMismatches: Integer;
    function Radius: Integer;
    function FMXBrushSize: Single;
    function MethodTitle(AIndex: Integer): string;
    function TimeFMXFilter: Double;
    procedure SetImage(const AImage: TImagePixels; const ADescription: string);
    procedure Log(const AText: string);
    procedure SetBusy(ABusy: Boolean);
    procedure SyncRadius;
    procedure RunMethod(AIndex: Integer);
    procedure RunBenchmark(ACPUIterations, AGPUIterations: Integer);
    procedure RunSelfTest(const ADirectory: string);
  end;

var
  MainForm: TMainForm;

implementation

{$R *.fmx}

uses
  System.IOUtils,
  ThumbnailCPU,
  FMX.Types3D,
  FMX.Filter.Standard; // registers the 'PencilStroke' filter behind TFilterPencilStroke

const
  // Method list: the TSketchMethod values, then the built-in FMX filter.
  FMXMethod = Ord(High(TSketchMethod)) + 1;

{$I 'ThumbnailMath.inc'}

procedure PixelsToBitmap(const AImage: TImagePixels; ABitmap: TBitmap);
var
  Data: TBitmapData;
  X, Y: Integer;
  Row: TArray<Cardinal>;
begin
  ABitmap.SetSize(AImage.Width, AImage.Height);
  SetLength(Row, AImage.Width);
  if not ABitmap.Map(TMapAccess.Write, Data) then
    raise EInvalidOpException.Create('Cannot map an FMX bitmap for writing');
  try
    for Y := 0 to AImage.Height - 1 do
    begin
      // WIC / engine pixels are straight BGRA; FMX bitmaps are premultiplied.
      for X := 0 to AImage.Width - 1 do
        Row[X] := ThumbnailPremultiply(AImage.Pixels[NativeInt(Y) * AImage.Width + X]);
      AlphaColorToScanline(@Row[0], Data.GetScanline(Y),
        AImage.Width, Data.PixelFormat);
    end;
  finally
    ABitmap.Unmap(Data);
  end;
end;

function BitmapToPixels(ABitmap: TBitmap): TImagePixels;
var
  Data: TBitmapData;
  Y: Integer;
  I: NativeInt;
begin
  Result.Width := ABitmap.Width;
  Result.Height := ABitmap.Height;
  SetLength(Result.Pixels, NativeInt(Result.Width) * Result.Height);
  if not ABitmap.Map(TMapAccess.Read, Data) then
    raise EInvalidOpException.Create('Cannot map an FMX bitmap for reading');
  try
    for Y := 0 to Result.Height - 1 do
      ScanlineToAlphaColor(Data.GetScanline(Y), @Result.Pixels[NativeInt(Y) * Result.Width],
        Result.Width, Data.PixelFormat);
  finally
    ABitmap.Unmap(Data);
  end;
  for I := 0 to High(Result.Pixels) do
    Result.Pixels[I] := ThumbnailUnpremultiply(Result.Pixels[I]);
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
  Method: TSketchMethod;
  GPU: string;
  I: Integer;
begin
  LogMemo.Lines.Clear;
  Caption := 'PasToSPIRV — эскиз и миниатюры (FMX)';
  OperationCombo.Items.Add('Карандашный эскиз');
  OperationCombo.Items.Add('Миниатюра (thumbnail)');
  OperationCombo.ItemIndex := 0;
  for I := Low(ThumbnailPresets) to High(ThumbnailPresets) do
    ThumbnailCombo.Items.Add(Format('%d x %d', [ThumbnailPresets[I].X, ThumbnailPresets[I].Y]));
  ThumbnailCombo.ItemIndex := 1;
  ThumbnailLabel.Text := 'Вписать в:';
  ThumbnailHint.Text := 'Пропорции сохранены, без увеличения; миниатюра показывается 1:1';
  OperationCombo.OnChange := OperationChanged;
  ThumbnailCombo.OnChange := OperationChanged;
  SizeCombo.Items.Add('1280 x 720');
  SizeCombo.Items.Add('1920 x 1080');
  SizeCombo.Items.Add('3840 x 2160');
  SizeCombo.ItemIndex := 1;
  // Assigned after ItemIndex: FMX combo boxes fire OnChange for programmatic changes too.
  SizeCombo.OnChange := TestButtonClick;
  FEngine := TSketchEngine.Create(DefaultShaderFile);
  FPencil := TFilterPencilStroke.Create(nil);
  FSourceBitmap := TBitmap.Create;
  for Method := Low(TSketchMethod) to High(TSketchMethod) do
    MethodCombo.Items.Add(SketchMethodName(Method));
  MethodCombo.Items.Add(MethodTitle(FMXMethod));
  if FEngine.GPUAvailable then
  begin
    MethodCombo.ItemIndex := Ord(smGPU);
    GPU := FEngine.GPUName;
  end
  else
  begin
    MethodCombo.ItemIndex := Ord(smCPUParallel);
    GPU := 'GPU недоступен: ' + FEngine.GPUError;
  end;
  StatusLabel.Text := Format('%s  |  %s  |  FMX: %s  |  таймер: QueryPerformanceCounter',
    [ProcessorName, GPU, TContextManager.DefaultContextClass.ClassName]);
  RadiusTrackChange(nil);
  OperationChanged(nil);
  Log('«Построить» — один запуск; для сравнения скорости — «Бенчмарк» (медиана после прогрева).');
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  FPencil.Free;
  FEngine.Free;
  FSourceBitmap.Free;
  FStockThumbnail.Free;
end;

procedure TMainForm.FormShow(Sender: TObject);
var
  Directory: string;
begin
  if (ParamCount = 2) and (ParamStr(1) = '--selftest') then
  begin
    Directory := ParamStr(2);
    TThread.ForceQueue(nil,
      procedure
      begin
        RunSelfTest(Directory);
      end);
  end
  else
    TestButtonClick(nil);
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := not FBusy;
end;

procedure TMainForm.ImagesLayoutResized(Sender: TObject);
begin
  SourceLayout.Width := (ImagesLayout.Width - Splitter.Width) / 2;
end;

function TMainForm.Radius: Integer;
begin
  Result := Round(RadiusTrack.Value);
end;

function TMainForm.FMXBrushSize: Single;
var
  Value: Double;
begin
  // brushSize shifts the filter's samples by that percentage of the image size (1..19).
  Value := Radius * 100 / Max(1, Max(FEngine.Image.Width, FEngine.Image.Height));
  Result := EnsureRange(Value, 1.0, 19.0);
end;

function TMainForm.MethodTitle(AIndex: Integer): string;
begin
  if AIndex = FMXMethod then
  begin
    if OperationCombo.ItemIndex = Ord(soThumbnail) then
      Result := 'FMX, TBitmap.CreateThumbnail'
    else
      Result := 'FMX, штатный TFilterPencilStroke';
  end
  else
    Result := SketchMethodName(TSketchMethod(AIndex));
end;

procedure TMainForm.Log(const AText: string);
begin
  LogMemo.Lines.Add(AText);
  LogMemo.GoToTextEnd;
  // Shows progress during long runs; the toolbar is disabled and closing is blocked meanwhile.
  if FBusy then
    Application.ProcessMessages;
end;

procedure TMainForm.SetBusy(ABusy: Boolean);
begin
  FBusy := ABusy;
  TopBar.Enabled := not ABusy;
  OptionsBar.Enabled := not ABusy;
  if ABusy then
    Application.ProcessMessages;
end;

procedure TMainForm.SetImage(const AImage: TImagePixels; const ADescription: string);
begin
  FEngine.SetImage(AImage, Radius);
  PixelsToBitmap(AImage, FSourceBitmap);
  SourceImage.Bitmap.Assign(FSourceBitmap);
  ResultImage.Bitmap.SetSize(0, 0);
  FResult := Default(TImagePixels);
  FHasResult := False;
  SourceCaption.Text := Format('Исходное: %s, %d x %d', [ADescription, AImage.Width, AImage.Height]);
  ResultCaption.Text := 'Эскиз';
end;

procedure TMainForm.OpenButtonClick(Sender: TObject);
begin
  if not OpenDialog.Execute then
    Exit;
  SetBusy(True);
  try
    SetImage(LoadImage(OpenDialog.FileName), ExtractFileName(OpenDialog.FileName));
    Log('Загружено: ' + OpenDialog.FileName);
  finally
    SetBusy(False);
  end;
end;

procedure TMainForm.TestButtonClick(Sender: TObject);
const
  Sizes: array[0..2] of TPoint = ((X: 1280; Y: 720), (X: 1920; Y: 1080), (X: 3840; Y: 2160));
var
  Index: Integer;
begin
  Index := EnsureRange(SizeCombo.ItemIndex, 0, High(Sizes));
  SetBusy(True);
  try
    SetImage(SyntheticImage(Sizes[Index].X, Sizes[Index].Y), 'тестовое');
  finally
    SetBusy(False);
  end;
end;

procedure TMainForm.RadiusTrackChange(Sender: TObject);
begin
  RadiusLabel.Text := Format('Радиус: %d', [Radius]);
end;

procedure TMainForm.SyncRadius;
var
  Index: Integer;
begin
  Index := EnsureRange(ThumbnailCombo.ItemIndex, Low(ThumbnailPresets), High(ThumbnailPresets));
  FEngine.Configure(TImageOperation(OperationCombo.ItemIndex), ThumbnailPresets[Index].X, ThumbnailPresets[Index].Y);
  if FEngine.Radius <> Radius then
    FEngine.SetImage(FEngine.Image, Radius);
end;

procedure TMainForm.OperationChanged(Sender: TObject);
var
  Index: Integer;
begin
  RadiusTrack.Enabled := OperationCombo.ItemIndex = Ord(soSketch);
  RadiusLabel.Enabled := RadiusTrack.Enabled;
  ThumbnailCombo.Enabled := not RadiusTrack.Enabled;
  ThumbnailLabel.Enabled := ThumbnailCombo.Enabled;
  ThumbnailHint.Enabled := ThumbnailCombo.Enabled;
  if MethodCombo.Items.Count > FMXMethod then
  begin
    Index := MethodCombo.ItemIndex;
    MethodCombo.Items[FMXMethod] := MethodTitle(FMXMethod);
    MethodCombo.ItemIndex := Index;
  end;
  FHasResult := False;
  FResult := Default(TImagePixels);
  ResultImage.Bitmap.SetSize(0, 0);
  ResultCaption.Text := 'Результат';
  ResultImage.WrapMode := TImageWrapMode.Place; // never magnify a saved thumbnail
end;

function TMainForm.TimeFMXFilter: Double;
var
  Start: Int64;
begin
  if FEngine.Operation = soThumbnail then
  begin
    FreeAndNil(FStockThumbnail);
    Start := TimerStart;
    FStockThumbnail := FSourceBitmap.CreateThumbnail(FEngine.OutputWidth, FEngine.OutputHeight);
    // Include the output Map/readback, not just asynchronous canvas commands.
    FStockPixels := BitmapToPixels(FStockThumbnail);
    Exit(TimerElapsedMs(Start));
  end;
  FPencil.brushSize := FMXBrushSize;
  Start := TimerStart;
  FPencil.Input := FSourceBitmap; // copied into a new FMX texture
  if FPencil.Output = nil then    // renders on the FMX GPU context and reads the result back
    raise EInvalidOpException.Create('TFilterPencilStroke returned no output');
  Result := TimerElapsedMs(Start);
end;

procedure TMainForm.RunMethod(AIndex: Integer);
var
  Outcome: TSketchResult;
  Differences: NativeInt;
  Text: string;
begin
  SyncRadius;
  if AIndex = FMXMethod then
  begin
    Outcome.Milliseconds := TimeFMXFilter;
    Outcome.ShaderMilliseconds := NaN;
    if FEngine.Operation = soSketch then
      FResult := BitmapToPixels(FPencil.Output)
    else
      FResult := FStockPixels;
  end
  else
  begin
    Outcome := FEngine.Run(TSketchMethod(AIndex));
    FResult.Width := FEngine.OutputWidth;
    FResult.Height := FEngine.OutputHeight;
    FResult.Pixels := Outcome.Pixels;
  end;
  FHasResult := True;
  PixelsToBitmap(FResult, ResultImage.Bitmap);
  Text := Format('%s: %.2f мс', [MethodTitle(AIndex), Outcome.Milliseconds]);
  if not IsNan(Outcome.ShaderMilliseconds) then
    Text := Text + Format(' (сам шейдер %.2f мс)', [Outcome.ShaderMilliseconds]);
  if AIndex = FMXMethod then
  begin
    if FEngine.Operation = soThumbnail then
      Text := Text + ' — штатное масштабирование FMX, побитово не сравнивается'
    else
      Text := Text + Format(' — brushSize %.1f; другой алгоритм, побитово не сравнивается', [FPencil.brushSize]);
    ResultCaption.Text := FEngine.Description + ': ' + MethodTitle(AIndex);
  end
  else
  begin
    if AIndex <> Ord(smCPUSingle) then
    begin
      Differences := CountDifferences(FEngine.Reference, Outcome.Pixels);
      if Differences = 0 then
        Text := Text + ' — бит-в-бит как CPU, 1 поток'
      else
      begin
        Text := Text + Format(' — ОТЛИЧАЕТСЯ от CPU в %d пикселях', [Differences]);
        Inc(FMismatches);
      end;
    end;
    ResultCaption.Text := FEngine.Description + ': ' + MethodTitle(AIndex);
  end;
  Log(Text);
end;

procedure TMainForm.RunButtonClick(Sender: TObject);
begin
  SetBusy(True);
  try
    RunMethod(MethodCombo.ItemIndex);
  finally
    SetBusy(False);
  end;
end;

procedure TMainForm.RunBenchmark(ACPUIterations, AGPUIterations: Integer);
var
  Index, I: Integer;
  Statistics: TSketchStatistics;
  Samples: TArray<Double>;
  Baseline: Double;
  Line: string;
begin
  SyncRadius;
  Log(Format('Бенчмарк: %s; исходное %d x %d (медиана после прогрева):',
    [FEngine.Description, FEngine.Image.Width, FEngine.Image.Height]));
  Baseline := NaN;
  for Index := Ord(Low(TSketchMethod)) to FMXMethod do
  begin
    if (Index = Ord(smGPU)) and not FEngine.GPUAvailable then
      Continue;
    if Index = FMXMethod then
    begin
      TimeFMXFilter; // warm-up: FMX context, shader and render targets
      SetLength(Samples, AGPUIterations);
      for I := 0 to High(Samples) do
        Samples[I] := TimeFMXFilter;
      Statistics.Median := MedianOf(Samples);
      Statistics.Minimum := MinValue(Samples);
      Statistics.ShaderMedian := NaN;
      Statistics.Iterations := AGPUIterations;
    end
    else if Index = Ord(smGPU) then
      Statistics := FEngine.Benchmark(smGPU, AGPUIterations)
    else
      Statistics := FEngine.Benchmark(TSketchMethod(Index), ACPUIterations);
    if Index = Ord(smCPUSingle) then
      Baseline := Statistics.Median;
    Line := Format('  %-34s %9.2f мс  (мин %.2f, x%.1f)', [MethodTitle(Index), Statistics.Median,
      Statistics.Minimum, Baseline / Statistics.Median]);
    if not IsNan(Statistics.ShaderMedian) then
      Line := Line + Format('; сам шейдер %.2f мс', [Statistics.ShaderMedian]);
    if (Index = FMXMethod) and (FEngine.Operation = soSketch) then
      Line := Line + Format('; brushSize %.1f, другой, более простой эффект', [FPencil.brushSize]);
    if (Index = FMXMethod) and (FEngine.Operation = soThumbnail) then
      Line := Line + '; штатное масштабирование FMX (другой фильтр)';
    Log(Line);
  end;
  if FEngine.GPUAvailable then
    Log(Format('  Подготовка GPU-буферов для этого размера: %.1f мс (однократно, не входит)',
      [FEngine.SetupMilliseconds]));
end;

procedure TMainForm.BenchButtonClick(Sender: TObject);
begin
  SetBusy(True);
  try
    RunBenchmark(3, 20);
  finally
    SetBusy(False);
  end;
end;

procedure TMainForm.SaveButtonClick(Sender: TObject);
begin
  if not FHasResult then
  begin
    Log('Сначала постройте эскиз или миниатюру');
    Exit;
  end;
  if SaveDialog.Execute then
  begin
    SavePng(SaveDialog.FileName, FResult);
    Log('Сохранено: ' + SaveDialog.FileName);
  end;
end;

procedure TMainForm.RunSelfTest(const ADirectory: string);
var
  Method: TSketchMethod;
  Screenshot: TBitmap;
  Window: TImagePixels;
  I: NativeInt;
begin
  ExitCode := 0;
  try
    ForceDirectories(ADirectory);
    SizeCombo.OnChange := nil;
    SizeCombo.ItemIndex := 0;
    SizeCombo.OnChange := TestButtonClick;
    TestButtonClick(nil);
    SetBusy(True);
    try
      RunMethod(FMXMethod);
      SavePng(TPath.Combine(ADirectory, 'fmx_stock.png'), FResult);
      for Method := Low(TSketchMethod) to High(TSketchMethod) do
        if (Method <> smGPU) or FEngine.GPUAvailable then
          RunMethod(Ord(Method));
      RunBenchmark(1, 3);
      SavePng(TPath.Combine(ADirectory, 'fmx_result.png'), FResult);
      OperationCombo.ItemIndex := Ord(soThumbnail);
      OperationChanged(nil);
      RunMethod(FMXMethod);
      SavePng(TPath.Combine(ADirectory, 'fmx_thumbnail_stock.png'), FResult);
      for Method := Low(TSketchMethod) to High(TSketchMethod) do
        if (Method <> smGPU) or FEngine.GPUAvailable then
          RunMethod(Ord(Method));
      SavePng(TPath.Combine(ADirectory, 'fmx_thumbnail.png'), FResult);
      RunBenchmark(1, 3);
    finally
      SetBusy(False);
    end;
    Screenshot := TBitmap.Create(ClientWidth, ClientHeight);
    try
      Screenshot.Clear(TAlphaColors.White);
      PaintTo(Screenshot.Canvas);
      Window := BitmapToPixels(Screenshot);
      for I := 0 to High(Window.Pixels) do
        Window.Pixels[I] := Window.Pixels[I] or $FF000000;
      SavePng(TPath.Combine(ADirectory, 'fmx_window.png'), Window);
    finally
      Screenshot.Free;
    end;
    LogMemo.Lines.SaveToFile(TPath.Combine(ADirectory, 'fmx_log.txt'), TEncoding.UTF8);
    if FMismatches > 0 then
      ExitCode := 3;
  except
    on E: Exception do
    begin
      TFile.WriteAllText(TPath.Combine(ADirectory, 'fmx_error.txt'), E.Message);
      ExitCode := 2;
    end;
  end;
  Close;
end;

end.
