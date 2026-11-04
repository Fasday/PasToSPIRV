unit MainVCL;

// VCL demo: pencil sketch and thumbnails on CPU (1 thread / all cores) or GPU through
// the PasToSPIRV shader, with timing and a bit-exact CPU/GPU comparison.

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  System.Math,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Dialogs,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  SketchImage,
  SketchEngine;

type
  TMainForm = class(TForm)
    TopPanel: TPanel;
    OpenButton: TButton;
    TestButton: TButton;
    SizeCombo: TComboBox;
    RadiusLabel: TLabel;
    RadiusTrack: TTrackBar;
    MethodCombo: TComboBox;
    RunButton: TButton;
    BenchButton: TButton;
    SaveButton: TButton;
    OptionsPanel: TPanel;
    OperationCombo: TComboBox;
    ThumbnailCombo: TComboBox;
    ThumbnailLabel: TLabel;
    ThumbnailHint: TLabel;
    ImagesPanel: TPanel;
    SourcePanel: TPanel;
    SourceCaption: TLabel;
    SourceImage: TImage;
    Splitter: TSplitter;
    ResultPanel: TPanel;
    ResultCaption: TLabel;
    ResultImage: TImage;
    LogMemo: TMemo;
    StatusBar: TStatusBar;
    OpenDialog: TOpenDialog;
    SaveDialog: TSaveDialog;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure ImagesPanelResize(Sender: TObject);
    procedure SplitterMoved(Sender: TObject);
    procedure OpenButtonClick(Sender: TObject);
    procedure TestButtonClick(Sender: TObject);
    procedure RadiusTrackChange(Sender: TObject);
    procedure OperationChanged(Sender: TObject);
    procedure RunButtonClick(Sender: TObject);
    procedure BenchButtonClick(Sender: TObject);
    procedure SaveButtonClick(Sender: TObject);
  private
    FEngine: TSketchEngine;
    FSourceBitmap: TBitmap;
    FResultBitmap: TBitmap;
    FResult: TImagePixels;
    FHasResult: Boolean;
    FMismatches: Integer;
    procedure SetImage(const AImage: TImagePixels; const ADescription: string);
    procedure ShowPreview(ATarget: TImage; ABitmap: TBitmap);
    procedure Log(const AText: string);
    procedure SetBusy(ABusy: Boolean);
    procedure SyncRadius;
    procedure RunMethod(AMethod: TSketchMethod);
    procedure RunBenchmark(ACPUIterations, AGPUIterations: Integer);
    procedure RunSelfTest(const ADirectory: string);
  end;

var
  MainForm: TMainForm;

implementation

{$R *.dfm}

uses
  System.IOUtils,
  ThumbnailCPU;

function PixelsToBitmap(const AImage: TImagePixels): TBitmap;
var
  Y: Integer;
begin
  Result := TBitmap.Create;
  Result.PixelFormat := pf32bit;
  Result.SetSize(AImage.Width, AImage.Height);
  for Y := 0 to AImage.Height - 1 do
    Move(AImage.Pixels[NativeInt(Y) * AImage.Width], Result.ScanLine[Y]^, AImage.Width * 4);
end;

function BitmapToPixels(ABitmap: TBitmap): TImagePixels;
var
  Y: Integer;
begin
  ABitmap.PixelFormat := pf32bit;
  Result.Width := ABitmap.Width;
  Result.Height := ABitmap.Height;
  SetLength(Result.Pixels, NativeInt(Result.Width) * Result.Height);
  for Y := 0 to Result.Height - 1 do
    Move(ABitmap.ScanLine[Y]^, Result.Pixels[NativeInt(Y) * Result.Width], Result.Width * 4);
  for Y := 0 to High(Result.Pixels) do
    Result.Pixels[Y] := Result.Pixels[Y] or $FF000000;
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
  Method: TSketchMethod;
  I: Integer;
begin
  LogMemo.Lines.Clear;
  Caption := 'PasToSPIRV — эскиз и миниатюры (VCL)';
  OperationCombo.Items.Add('Карандашный эскиз');
  OperationCombo.Items.Add('Миниатюра (thumbnail)');
  OperationCombo.ItemIndex := 0;
  for I := Low(ThumbnailPresets) to High(ThumbnailPresets) do
    ThumbnailCombo.Items.Add(Format('%d x %d', [ThumbnailPresets[I].X, ThumbnailPresets[I].Y]));
  ThumbnailCombo.ItemIndex := 1;
  ThumbnailLabel.Caption := 'Вписать в:';
  ThumbnailHint.Caption := 'Пропорции сохранены, без увеличения; миниатюра показывается 1:1';
  OperationCombo.OnChange := OperationChanged;
  ThumbnailCombo.OnChange := OperationChanged;
  OperationChanged(nil);
  for Method := Low(TSketchMethod) to High(TSketchMethod) do
    MethodCombo.Items.Add(SketchMethodName(Method));
  SizeCombo.ItemIndex := 1;
  FEngine := TSketchEngine.Create(DefaultShaderFile);
  if FEngine.GPUAvailable then
  begin
    MethodCombo.ItemIndex := Ord(smGPU);
    StatusBar.SimpleText := Format('%s  |  %s  |  таймер: QueryPerformanceCounter',
      [ProcessorName, FEngine.GPUName]);
  end
  else
  begin
    MethodCombo.ItemIndex := Ord(smCPUParallel);
    StatusBar.SimpleText := ProcessorName + '  |  GPU недоступен: ' + FEngine.GPUError;
  end;
  RadiusTrackChange(nil);
  Log('«Построить» — один запуск; для сравнения скорости — «Бенчмарк» (медиана после прогрева).');
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  FEngine.Free;
  FSourceBitmap.Free;
  FResultBitmap.Free;
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

procedure TMainForm.Log(const AText: string);
begin
  LogMemo.Lines.Add(AText);
  LogMemo.Update;
end;

procedure TMainForm.SetBusy(ABusy: Boolean);
begin
  TopPanel.Enabled := not ABusy;
  OptionsPanel.Enabled := not ABusy;
  if ABusy then
    Screen.Cursor := crHourGlass
  else
    Screen.Cursor := crDefault;
  Update;
end;

procedure TMainForm.ShowPreview(ATarget: TImage; ABitmap: TBitmap);
var
  Preview: TBitmap;
  Scale: Double;
  Width, Height: Integer;
begin
  if (ABitmap = nil) or (ATarget.Width < 2) or (ATarget.Height < 2) then
  begin
    ATarget.Picture := nil;
    Exit;
  end;
  // Halftone downscaling keeps thin pencil lines visible in the preview.
  Scale := Min(1.0, Min(ATarget.Width / ABitmap.Width, ATarget.Height / ABitmap.Height));
  Width := Max(1, Round(ABitmap.Width * Scale));
  Height := Max(1, Round(ABitmap.Height * Scale));
  Preview := TBitmap.Create;
  try
    Preview.PixelFormat := pf32bit;
    Preview.SetSize(Width, Height);
    SetStretchBltMode(Preview.Canvas.Handle, HALFTONE);
    SetBrushOrgEx(Preview.Canvas.Handle, 0, 0, nil);
    StretchBlt(Preview.Canvas.Handle, 0, 0, Width, Height, ABitmap.Canvas.Handle, 0, 0,
      ABitmap.Width, ABitmap.Height, SRCCOPY);
    ATarget.Picture.Assign(Preview);
  finally
    Preview.Free;
  end;
end;

procedure TMainForm.ImagesPanelResize(Sender: TObject);
begin
  SourcePanel.Width := (ImagesPanel.ClientWidth - Splitter.Width) div 2;
  ShowPreview(SourceImage, FSourceBitmap);
  ShowPreview(ResultImage, FResultBitmap);
end;

procedure TMainForm.SplitterMoved(Sender: TObject);
begin
  ShowPreview(SourceImage, FSourceBitmap);
  ShowPreview(ResultImage, FResultBitmap);
end;

procedure TMainForm.SetImage(const AImage: TImagePixels; const ADescription: string);
begin
  FEngine.SetImage(AImage, RadiusTrack.Position);
  FreeAndNil(FSourceBitmap);
  FreeAndNil(FResultBitmap);
  FHasResult := False;
  FResult := Default(TImagePixels);
  FSourceBitmap := PixelsToBitmap(AImage);
  SourceCaption.Caption := Format('Исходное: %s, %d x %d', [ADescription, AImage.Width, AImage.Height]);
  ResultCaption.Caption := 'Эскиз';
  ShowPreview(SourceImage, FSourceBitmap);
  ShowPreview(ResultImage, nil);
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
begin
  SetBusy(True);
  try
    SetImage(SyntheticImage(Sizes[SizeCombo.ItemIndex].X, Sizes[SizeCombo.ItemIndex].Y), 'тестовое');
  finally
    SetBusy(False);
  end;
end;

procedure TMainForm.RadiusTrackChange(Sender: TObject);
begin
  RadiusLabel.Caption := Format('Радиус: %d', [RadiusTrack.Position]);
end;

procedure TMainForm.SyncRadius;
var
  Index: Integer;
begin
  Index := EnsureRange(ThumbnailCombo.ItemIndex, Low(ThumbnailPresets), High(ThumbnailPresets));
  FEngine.Configure(TImageOperation(OperationCombo.ItemIndex), ThumbnailPresets[Index].X, ThumbnailPresets[Index].Y);
  if FEngine.Radius <> RadiusTrack.Position then
    FEngine.SetImage(FEngine.Image, RadiusTrack.Position);
end;

procedure TMainForm.OperationChanged(Sender: TObject);
begin
  RadiusTrack.Enabled := OperationCombo.ItemIndex = Ord(soSketch);
  RadiusLabel.Enabled := RadiusTrack.Enabled;
  ThumbnailCombo.Enabled := not RadiusTrack.Enabled;
  ThumbnailLabel.Enabled := ThumbnailCombo.Enabled;
  ThumbnailHint.Enabled := ThumbnailCombo.Enabled;
  FHasResult := False;
  FResult := Default(TImagePixels);
  FreeAndNil(FResultBitmap);
  ResultImage.Picture := nil;
  ResultCaption.Caption := 'Результат';
end;

procedure TMainForm.RunMethod(AMethod: TSketchMethod);
var
  Outcome: TSketchResult;
  Differences: NativeInt;
  Text: string;
begin
  SyncRadius;
  Outcome := FEngine.Run(AMethod);
  FResult.Width := FEngine.OutputWidth;
  FResult.Height := FEngine.OutputHeight;
  FResult.Pixels := Outcome.Pixels;
  FHasResult := True;
  FreeAndNil(FResultBitmap);
  FResultBitmap := PixelsToBitmap(FResult);
  ShowPreview(ResultImage, FResultBitmap);
  Text := Format('%s: %.2f мс', [SketchMethodName(AMethod), Outcome.Milliseconds]);
  if not IsNan(Outcome.ShaderMilliseconds) then
    Text := Text + Format(' (сам шейдер %.2f мс)', [Outcome.ShaderMilliseconds]);
  if AMethod <> smCPUSingle then
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
  ResultCaption.Caption := FEngine.Description + ': ' + SketchMethodName(AMethod);
  Log(Text);
end;

procedure TMainForm.RunButtonClick(Sender: TObject);
begin
  SetBusy(True);
  try
    RunMethod(TSketchMethod(MethodCombo.ItemIndex));
  finally
    SetBusy(False);
  end;
end;

procedure TMainForm.RunBenchmark(ACPUIterations, AGPUIterations: Integer);
var
  Method: TSketchMethod;
  Statistics: TSketchStatistics;
  Baseline: Double;
  Line: string;
begin
  SyncRadius;
  Log(Format('Бенчмарк: %s; исходное %d x %d (медиана после прогрева):',
    [FEngine.Description, FEngine.Image.Width, FEngine.Image.Height]));
  Baseline := NaN;
  for Method := Low(TSketchMethod) to High(TSketchMethod) do
  begin
    if (Method = smGPU) and not FEngine.GPUAvailable then
      Continue;
    if Method = smGPU then
      Statistics := FEngine.Benchmark(Method, AGPUIterations)
    else
      Statistics := FEngine.Benchmark(Method, ACPUIterations);
    if Method = smCPUSingle then
      Baseline := Statistics.Median;
    Line := Format('  %-34s %9.2f мс  (мин %.2f, x%.1f)', [SketchMethodName(Method), Statistics.Median,
      Statistics.Minimum, Baseline / Statistics.Median]);
    if not IsNan(Statistics.ShaderMedian) then
      Line := Line + Format('; сам шейдер %.2f мс', [Statistics.ShaderMedian]);
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
begin
  ExitCode := 0;
  try
    ForceDirectories(ADirectory);
    SizeCombo.ItemIndex := 0;
    TestButtonClick(nil);
    for Method := Low(TSketchMethod) to High(TSketchMethod) do
      if (Method <> smGPU) or FEngine.GPUAvailable then
        RunMethod(Method);
    RunBenchmark(1, 3);
    SavePng(TPath.Combine(ADirectory, 'vcl_result.png'), FResult);
    OperationCombo.ItemIndex := Ord(soThumbnail);
    OperationChanged(nil);
    for Method := Low(TSketchMethod) to High(TSketchMethod) do
      if (Method <> smGPU) or FEngine.GPUAvailable then
        RunMethod(Method);
    RunBenchmark(1, 3);
    SavePng(TPath.Combine(ADirectory, 'vcl_thumbnail.png'), FResult);
    Screenshot := GetFormImage;
    try
      SavePng(TPath.Combine(ADirectory, 'vcl_window.png'), BitmapToPixels(Screenshot));
    finally
      Screenshot.Free;
    end;
    LogMemo.Lines.SaveToFile(TPath.Combine(ADirectory, 'vcl_log.txt'), TEncoding.UTF8);
    if FMismatches > 0 then
      ExitCode := 3;
  except
    on E: Exception do
    begin
      TFile.WriteAllText(TPath.Combine(ADirectory, 'vcl_error.txt'), E.Message);
      ExitCode := 2;
    end;
  end;
  Close;
end;

end.
