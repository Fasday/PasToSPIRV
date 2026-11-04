program SketchFMX;

// FireMonkey demo of the pencil-sketch example: CPU (1 thread / all cores), the
// PasToSPIRV compute shader on Vulkan and FireMonkey's built-in TFilterPencilStroke.
// Build with examples\sketch\build.ps1.
//   SketchFMX [--selftest DIR]

uses
  Winapi.ActiveX,
  FMX.Forms,
  SketchShaderBindings in '..\..\build\sketch\SketchShaderBindings.pas',
  SketchImage in 'SketchImage.pas',
  SketchCPU in 'SketchCPU.pas',
  SketchVulkan in 'SketchVulkan.pas',
  SketchEngine in 'SketchEngine.pas',
  MainFMX in 'MainFMX.pas' {MainForm};

{$R '..\..\build\res\SketchDemo.res'}

begin
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    PTS_ValidateLayouts;
    Application.Initialize;
    Application.CreateForm(TMainForm, MainForm);
    Application.Run;
  finally
    CoUninitialize;
  end;
end.
