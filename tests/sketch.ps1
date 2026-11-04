# Sketch example: the shader always compiles/validates; with Delphi the app is
# built and its CPU paths are run (GPU comparison lives in tests/vulkan_smoke.py).
$sketchDir = Join-Path $root 'examples\sketch'
$sketchOut = Join-Path $root 'build\sketch'
New-Item -ItemType Directory -Force -Path $sketchOut | Out-Null
$sketchShader = Join-Path $sketchOut 'sketch.spv'
$result = Invoke-Tool $compiler @('compile', (Join-Path $sketchDir 'sketch.pas'), '-I', $sketchDir, '-O1',
    '-o', $sketchShader, '--bindings', (Join-Path $sketchOut 'SketchShaderBindings.pas'))
Assert-True ($result.Code -eq 0) "Sketch shader failed to compile: $($result.Err)"
$validation = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.0', $sketchShader)
Assert-True ($validation.Code -eq 0) "Sketch shader is invalid: $($validation.Err)"
$script:checks++

if (-not $SkipDelphiTests) {
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $sketchDir 'SketchBench.dpr')
    $bench = Invoke-Tool (Join-Path $root 'build\bin\SketchBench.exe') @('--cpu-only', '--sizes', '97x61,64x48',
        '--cpu-iterations', '1', '--radius', '32', '--out', (Join-Path $cases 'sketch'))
    Assert-True ($bench.Code -eq 0 -and $bench.Out -notmatch 'ERROR') "Sketch CPU paths failed: $($bench.Out)$($bench.Err)"
    Assert-True (Test-Path (Join-Path $cases 'sketch\sketch_cpu.png')) 'Sketch output image was not written'
    $script:checks++
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\ThumbnailCheck.dpr')
    $thumbnail = Invoke-Tool (Join-Path $root 'build\bin\ThumbnailCheck.exe') @()
    Assert-True ($thumbnail.Code -eq 0 -and $thumbnail.Out -match 'PASS: thumbnails CPU oracle') `
        "Thumbnail CPU regression failed: $($thumbnail.Out)$($thumbnail.Err)"
    $script:checks++
    # GUI demos are only compiled here; `SketchVCL.exe --selftest DIR` runs them interactively.
    $guiOutput = Join-Path $cases 'sketch-gui'
    foreach ($demo in 'SketchVCL', 'SketchFMX') {
        & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $sketchDir "$demo.dpr") `
            -Resources (Join-Path $sketchDir 'SketchDemo.rc') -OutputDirectory $guiOutput
        Assert-True (Test-Path (Join-Path $guiOutput "$demo.exe")) "$demo was not built"
        $script:checks++
    }
}
else { Write-Warning 'Sketch application build/run was explicitly skipped (-SkipDelphiTests).' }
