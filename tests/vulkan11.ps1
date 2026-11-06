$vulkan11Source = @'
var
  [Binding(0,0)] Bytes: array of Byte;
  [Binding(0,1)] Words: array of Word;
  [Binding(0,2)] Doubles: array of Double;
[Vulkan11, StrictFloat]
procedure Main;
var
  Value: UInt64;
begin
  Value := UInt64(42);
  Bytes[0] := Byte(Value);
  Words[0] := Word(Value);
  Doubles[0] := Double(Value);
end;
'@
$vulkan11Path = Join-Path $cases 'vulkan11.pas'
$vulkan11Output = Join-Path $cases 'vulkan11.spv'
[IO.File]::WriteAllText($vulkan11Path, $vulkan11Source, $utf8)
$vulkan11Result = Invoke-Tool $compiler @('compile', $vulkan11Path, '-o', $vulkan11Output)
Assert-True ($vulkan11Result.Code -eq 0) "Vulkan11 failed: $($vulkan11Result.Err)"
$vulkan11Validation = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.1', $vulkan11Output)
Assert-True ($vulkan11Validation.Code -eq 0) "Vulkan11 SPIR-V invalid: $($vulkan11Validation.Out)$($vulkan11Validation.Err)"
$vulkan11Meta = Get-Content ([IO.Path]::ChangeExtension($vulkan11Output, '.json')) -Raw | ConvertFrom-Json
Assert-True ($vulkan11Meta.profile -eq 'compute-vulkan1.1' -and $vulkan11Meta.target_env -eq 'vulkan1.1') 'Vulkan11 profile reflection mismatch'
Assert-True ($vulkan11Meta.spirv_version -eq '1.3') 'Vulkan11 must use SPIR-V 1.3'
foreach ($extension in @('VK_KHR_shader_float16_int8', 'VK_KHR_8bit_storage', 'VK_KHR_shader_float_controls')) {
    Assert-True ($extension -in $vulkan11Meta.required_device_extensions) "Vulkan11 omitted $extension"
}
foreach ($feature in @('shaderInt64', 'shaderFloat64', 'shaderInt8', 'shaderInt16', 'storageBuffer8BitAccess', 'storageBuffer16BitAccess')) {
    Assert-True ($feature -in $vulkan11Meta.required_features) "Vulkan11 omitted $feature"
}
$vulkan12Path = Join-Path $cases 'vulkan11-native-comparison.pas'
$vulkan12Output = Join-Path $cases 'vulkan11-native-comparison.spv'
[IO.File]::WriteAllText($vulkan12Path, $vulkan11Source.Replace('Vulkan11', 'Vulkan12'), $utf8)
$vulkan12Result = Invoke-Tool $compiler @('compile', $vulkan12Path, '-o', $vulkan12Output)
Assert-True ($vulkan12Result.Code -eq 0) "Vulkan12 comparison failed: $($vulkan12Result.Err)"
Assert-True ((Get-FileHash $vulkan11Output).Hash -eq (Get-FileHash $vulkan12Output).Hash) 'Targeting 1.1 must not change the extended instruction stream'
$script:checks += 11

Test-Failure 'vulkan11_duplicate' '[Vulkan11, Vulkan11] procedure Main; begin end;' 'Duplicate Vulkan11'
Test-Failure 'vulkan11_conflict' '[Vulkan11, Vulkan12] procedure Main; begin end;' 'cannot be combined'
Test-Failure 'vulkan11_conflict_reverse' '[Vulkan12, Vulkan11] procedure Main; begin end;' 'cannot be combined'
Test-Failure 'vulkan11_resource_attribute' 'var [Vulkan11,Binding(0,0)] Data: array of Cardinal; procedure Main; begin end;' 'only valid on procedure Main'
