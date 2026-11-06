if (-not $SkipDelphiTests) {
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\ComponentCheck.dpr')
    $component = Invoke-Tool (Join-Path $root 'build\bin\ComponentCheck.exe') @() $root
    Assert-True ($component.Code -eq 0) "Runtime component API failed: $($component.Out)$($component.Err)"
    $validation = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.0', (Join-Path $root 'build\component.spv'))
    Assert-True ($validation.Code -eq 0) "Runtime component emitted invalid SPIR-V: $($validation.Out)$($validation.Err)"
    $script:checks += 2
}
