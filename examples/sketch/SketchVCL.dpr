program SketchVCL;

// VCL demo of the pencil-sketch example: CPU (1 thread / all cores) versus the
// PasToSPIRV compute shader on Vulkan. Build with examples\sketch\build.ps1.
//   SketchVCL [--selftest DIR]

uses
  Winapi.ActiveX,
  Vcl.Forms,
  SketchShaderBindings in '..\..\build\sketch\SketchShaderBindings.pas',
  SketchImage in 'SketchImage.pas',
  SketchCPU in 'SketchCPU.pas',
  SketchVulkan in 'SketchVulkan.pas',
  SketchEngine in 'SketchEngine.pas',
  MainVCL in 'MainVCL.pas' {MainForm};

{$R '..\..\build\res\SketchDemo.res'}

begin
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    PTS_ValidateLayouts;
    Application.Initialize;
    Application.MainFormOnTaskbar := True;
    Application.CreateForm(TMainForm, MainForm);
    Application.Run;
  finally
    CoUninitialize;
  end;
end.
