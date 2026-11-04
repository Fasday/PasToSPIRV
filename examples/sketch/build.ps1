# Builds the sketch/thumbnail example: shader (PasToSPIRV), SketchBench.exe and the
# SketchVCL.exe / SketchFMX.exe GUI demos (Delphi).
#   .\examples\sketch\build.ps1
#   .\build\bin\SketchBench.exe [image.png]
param([string]$DelphiRoot = $env:BDS)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$compiler = Join-Path $root 'build\bin\PasToSPIRV.exe'
$output = Join-Path $root 'build\sketch'

if (-not (Test-Path $compiler)) {
    & (Join-Path $root 'scripts\build.ps1') -DelphiRoot $DelphiRoot
}
New-Item -ItemType Directory -Force -Path $output | Out-Null

# Shader and CPU share SketchMath.inc/ThumbnailMath.inc; -O1 folds integer constants only.
& $compiler compile (Join-Path $PSScriptRoot 'sketch.pas') -I $PSScriptRoot -O1 `
    -o (Join-Path $output 'sketch.spv') --bindings (Join-Path $output 'SketchShaderBindings.pas')
if ($LASTEXITCODE -ne 0) { throw "Shader compilation failed (exit code $LASTEXITCODE)." }

$validator = Get-Command spirv-val -ErrorAction SilentlyContinue
if ($validator) {
    & $validator.Source --target-env vulkan1.0 (Join-Path $output 'sketch.spv')
    if ($LASTEXITCODE -ne 0) { throw 'spirv-val rejected sketch.spv.' }
}
else { Write-Warning 'spirv-val not found; SPIR-V validation skipped.' }

& (Join-Path $root 'scripts\build.ps1') -DelphiRoot $DelphiRoot -Project (Join-Path $PSScriptRoot 'SketchBench.dpr')
# GUI demos share a manifest resource (themed controls, per-monitor DPI).
foreach ($demo in 'SketchVCL.dpr', 'SketchFMX.dpr') {
    & (Join-Path $root 'scripts\build.ps1') -DelphiRoot $DelphiRoot -Project (Join-Path $PSScriptRoot $demo) `
        -Resources (Join-Path $PSScriptRoot 'SketchDemo.rc')
}
Write-Host "Run: $(Join-Path $root 'build\bin\SketchBench.exe') [image]"
Write-Host "GUI: $(Join-Path $root 'build\bin\SketchVCL.exe'), $(Join-Path $root 'build\bin\SketchFMX.exe')"
