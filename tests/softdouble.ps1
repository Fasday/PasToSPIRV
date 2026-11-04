# lib/SoftDouble.pasm: compiles as a module (O0/O1, Vulkan 1.2 validation),
# reflects its device features and rejects the Vulkan 1.0 profile.
# Bit-exact GPU results: python tests/softdouble_gpu.py (needs SoftDoubleCheck.exe).
$softCases = Join-Path $cases 'softdouble'
New-Item -ItemType Directory -Force -Path $softCases | Out-Null
$softLib = Join-Path $root 'lib'
$softSource = Join-Path $root 'tests\fixtures\softdouble_div.pas'
foreach ($mode in @('O0', 'O1')) {
    $softOut = Join-Path $softCases "softdouble_div_$mode.spv"
    $softArgs = @('compile', $softSource, '-I', $softLib, '-o', $softOut)
    if ($mode -eq 'O1') { $softArgs += '-O1' }
    $soft = Invoke-Tool $compiler $softArgs
    Assert-True ($soft.Code -eq 0) "SoftDouble $mode failed: $($soft.Err)"
    $softVal = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.2', $softOut)
    Assert-True ($softVal.Code -eq 0) "SoftDouble $mode invalid: $($softVal.Err)"
    $softMeta = Get-Content ([IO.Path]::ChangeExtension($softOut, '.json')) -Raw | ConvertFrom-Json
    Assert-True (($softMeta.required_features -contains 'shaderInt64') -and ($softMeta.required_features -contains 'shaderFloat64')) 'SoftDouble must reflect shaderInt64 and shaderFloat64'
    Assert-True (@($softMeta.modules | Where-Object { $_.name -eq 'SoftDouble' }).Count -eq 1) 'SoftDouble module is not listed in reflection'
    $script:checks++
}

# Bits-only use does not need shaderFloat64.
$bitsOnly = Join-Path $softCases 'bits_only.pas'
[IO.File]::WriteAllText($bitsOnly, "uses SoftDouble; var [Binding(0,0)] D: array of UInt64; [Vulkan12] procedure Main; begin D[0] := SoftDivBits(D[1], D[2]); end;", $utf8)
$bitsOut = Join-Path $softCases 'bits_only.spv'
$bits = Invoke-Tool $compiler @('compile', $bitsOnly, '-I', $softLib, '-o', $bitsOut)
Assert-True ($bits.Code -eq 0) "SoftDivBits failed: $($bits.Err)"
$script:checks++

$legacy = Join-Path $softCases 'legacy_profile.pas'
[IO.File]::WriteAllText($legacy, "uses SoftDouble; procedure Main; begin end;", $utf8)
$legacyRun = Invoke-Tool $compiler @('compile', $legacy, '-I', $softLib, '-o', (Join-Path $softCases 'legacy_profile.spv'))
Assert-True ($legacyRun.Code -eq 1 -and $legacyRun.Err -match 'requires \[Vulkan12\]') "SoftDouble without Vulkan12 must fail: $($legacyRun.Err)"
$script:checks++

if (-not $SkipDelphiTests) {
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\SoftDoubleCheck.dpr')
}
