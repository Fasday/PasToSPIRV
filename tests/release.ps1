# Release feature/diagnostic and project-cache tests; loaded by test.ps1.
$successes = @(
    @('const_integer', 'const N: Cardinal = 8 * 8; M = (N shl 1) + 1; type TData = array[0..N-1] of Cardinal; var [Binding(0,0)] Data: array of TData; [LocalSize(N,1,1)] procedure Main; begin Data[0][0] := M; end;'),
    @('const_wrapping', 'const A: Cardinal = $FFFFFFFF + 1; B = -2147483648; C = -7 div 3; D = -7 mod 3; E = -1 shr 33; procedure Main; var I: Integer; begin I := C + D + E; end;'),
    @('const_float_bool', 'const Scale: Single = 1 / 2; Enabled: Boolean = (3 < 5) and not False; procedure Main; var F: Single; begin if Enabled then F := Scale; end;'),
    @('atomic_component', 'var [Binding(0,0)] Data: array of Cardinal3; procedure Main; begin AtomicAdd(Data[0].X,1); end;'),
    @('shared_atomic', 'var [Shared] Data: array[0..15] of Integer; procedure Main; begin Data[LocalInvocationIndex] := 0; Barrier(); AtomicAdd(Data[0],1); Barrier; end;'),
    @('memory_barriers', 'procedure Main; begin BufferMemoryBarrier; ImageMemoryBarrier(); end;'),
    @('builtin_vectors', 'procedure Main; var V: Cardinal3; I: Cardinal; begin V := WorkgroupID + NumWorkgroups + LocalInvocationID; I := LocalInvocationIndex; end;')
)
foreach ($case in $successes) { Test-Success $case[0] $case[1] }
$failures = @(
    @('const_undefined', 'const A = Missing + 1; procedure Main; begin end;', 'Unknown identifier'),
    @('const_div_zero', 'const A = 1 div 0; procedure Main; begin end;', 'defined scalar constant'),
    @('const_div_overflow', 'const A = -2147483648 div -1; procedure Main; begin end;', 'defined scalar constant'),
    @('const_float_overflow', 'const A = 1e30 * 1e30; procedure Main; begin end;', 'defined scalar constant'),
    @('const_write', 'const A = 3; procedure Main; begin A := 4; end;', 'read-only'),
    @('const_vector_count', 'const A: Single3 = (1, 2); procedure Main; begin end;', 'between vector components'),
    @('const_vector_runtime', 'const A: Single3 = Single3(Sqrt(2)); procedure Main; begin end;', 'defined constant element'),
    @('const_builtin', 'const A = GlobalInvocationID.X; procedure Main; begin end;', 'GPU built-ins'),
    @('atomic_local', 'procedure Main; var I: Integer; begin I := 0; AtomicAdd(I,1); end;', 'ReadWrite storage buffer or shared'),
    @('atomic_float', 'var [Binding(0,0)] Data: array of Single; procedure Main; begin AtomicAdd(Data[0],1); end;', 'scalar Integer or Cardinal'),
    @('atomic_readonly', 'var [Binding(0,0),ReadOnly] Data: array of Cardinal; procedure Main; begin AtomicAdd(Data[0],1); end;', 'ReadOnly'),
    @('atomic_writeonly', 'var [Binding(0,0),WriteOnly] Data: array of Cardinal; procedure Main; begin AtomicAdd(Data[0],1); end;', 'ReadWrite'),
    @('barrier_if', 'procedure Main; begin if True then Barrier; end;', 'unconditional'),
    @('barrier_while', 'procedure Main; begin while False do Barrier; end;', 'unconditional'),
    @('barrier_for', 'procedure Main; var I: Integer; begin for I := 1 to 2 do Barrier; end;', 'unconditional'),
    @('barrier_helper', 'function F: Integer; begin Barrier; Result := 1; end; procedure Main; begin end;', 'only available in Main'),
    @('shared_vector', 'var [Shared] Data: array[0..3] of Single3; procedure Main; begin end;', 'one-dimensional array'),
    @('shared_large', 'var [Shared] Data: array[0..4096] of Cardinal; procedure Main; begin end;', '16 KiB'),
    @('shared_binding', 'var [Shared,Binding(0,0)] Data: array[0..3] of Cardinal; procedure Main; begin end;', 'cannot have bindings'),
    @('image_readonly', 'var [Binding(0,0),ReadOnly] Data: Image2D_R32UInt; procedure Main; begin ImageStore(Data,Integer2(0),Cardinal4(0)); end;', 'ReadOnly'),
    @('image_writeonly', 'var [Binding(0,0),WriteOnly] Data: Image2D_R32UInt; procedure Main; var V: Cardinal4; begin V := ImageLoad(Data,Integer2(0)); end;', 'WriteOnly'),
    @('image_coordinate', 'var [Binding(0,0)] Data: Image2D_R32UInt; procedure Main; var V: Cardinal4; begin V := ImageLoad(Data,0); end;', 'Integer2 or Cardinal2'),
    @('image_opaque_value', 'var [Binding(0,0)] Data: Image2D_R32UInt; procedure Main; var V: Cardinal4; begin V := Data; end;', 'Opaque resources'),
    @('image_binding_collision', 'var [Binding(0,0)] A: Image2D_R32UInt; [Binding(0,0)] B: array of Cardinal; procedure Main; begin end;', 'Duplicate descriptor'),
    @('sample_coordinate', 'var [Binding(0,0)] T: Texture2D; [Binding(0,1)] S: Sampler; procedure Main; var V: Single4; begin V := SampleLevel(T,S,0,0); end;', 'Cannot convert'),
    @('texture_write', 'var [Binding(0,0),WriteOnly] T: Texture2D; procedure Main; begin end;', 'read-only')
)
foreach ($case in $failures) { if ($case[2]) { Test-Failure $case[0] $case[1] $case[2] } }
$nsFiles = @{
    'main.pas' = [IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\const_namespace.pas'))
    'A.pasm' = [IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\release_modules\A.pasm'))
    'B.pasm' = [IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\release_modules\B.pasm'))
}
[void](Test-SourceProject 'qualified_constants_types' $nsFiles)
foreach ($imageType in @('Image2D_R32UInt','Image2D_R32Int','Image2D_RGBA32Float','Image2D_RGBA8')) {
    Test-Success "format_$imageType" "var [Binding(0,0),ReadOnly] A: $imageType; [Binding(0,1),WriteOnly] B: $imageType; procedure Main; begin ImageStore(B,Integer2(0),ImageLoad(A,Integer2(0))); end;" 'OpImageWrite'
}
$dependency = Join-Path $simple 'helper.inc'
$before = (Get-FileHash $dependency).Hash
$collision = Invoke-Tool $compiler @((Join-Path $simple 'main.pas'),'-o',$dependency)
Assert-True ($collision.Code -eq 2 -and (Get-FileHash $dependency).Hash -eq $before) 'Compile command overwrote an included dependency'
$script:checks++

# O1 must fold only safe integral constants, not undefined division or floating math.
$optimizerSource = 'var [Binding(0,0)] Data: array of Integer; procedure Main; begin Data[0] := (2 + 3) * 7; Data[1] := 1 div 0; end;'
Test-Success 'optimizer_input' $optimizerSource 'OpIAdd'
$optimized = Join-Path $cases 'optimized.spv'
$result = Invoke-Tool $compiler @((Join-Path $cases 'optimizer_input.pas'),'-O1','-o',$optimized)
Assert-True ($result.Code -eq 0) "Optimizer failed: $($result.Err)"
$validation = Invoke-Tool $SpirvVal @('--target-env','vulkan1.0',$optimized)
Assert-True ($validation.Code -eq 0) 'Optimized module is invalid'
$assembly = Invoke-Tool $SpirvDis @($optimized)
Assert-True ($assembly.Out -notmatch '\bOpIAdd\b' -and $assembly.Out -match '\bOpSDiv\b') 'Optimizer folded incorrectly or dropped undefined arithmetic'
$script:checks++

$projectDir = Join-Path $cases 'project-cache'
New-Item -ItemType Directory -Force -Path (Join-Path $projectDir 'lib') | Out-Null
if (Test-Path (Join-Path $projectDir 'Util.pasm')) { Remove-Item -LiteralPath (Join-Path $projectDir 'Util.pasm') }
[IO.File]::WriteAllText((Join-Path $projectDir 'first.pas'),'uses Util; var [Binding(0,0)] Data: array of Integer; procedure Main; begin Data[0] := F(); end;',$utf8)
[IO.File]::WriteAllText((Join-Path $projectDir 'second.pas'),'procedure Main; begin end;',$utf8)
[IO.File]::WriteAllText((Join-Path $projectDir 'lib\Util.pasm'),'module Util; function F: Integer; begin Result := 1 + 2; end;',$utf8)
$config = @{ format_version = 1; include_directories = @('lib'); optimize = $true; entries = @(
    @{ source='first.pas'; output='out/first.spv'; bindings='out/FirstBindings.pas' },
    @{ source='second.pas'; output='out/second.spv' }
) }
$projectPath = Join-Path $projectDir 'project.json'
[IO.File]::WriteAllText($projectPath,($config | ConvertTo-Json -Depth 10),$utf8)
function Check-Build([string]$Expected,[switch]$Force) {
    $arguments = @('build',$projectPath)
    if ($Force) { $arguments += '--force' }
    $r = Invoke-Tool $compiler $arguments
    Assert-True ($r.Code -eq 0 -and $r.Out -match $Expected) "Project build failed: $($r.Out)$($r.Err)"
    $script:checks++
}
# Force is deliberate: this fixture may remain from a previous regression run.
Check-Build 'Built: 2; cached: 0' -Force
Check-Build 'Built: 0; cached: 2'
[IO.File]::WriteAllText((Join-Path $projectDir 'lib\Util.pasm'),'module Util; function F: Integer; begin Result := 3 + 4; end;',$utf8)
Check-Build 'Built: 1; cached: 1'
[IO.File]::WriteAllText((Join-Path $projectDir 'out\first.spv'),'corrupt',$utf8)
Check-Build 'Built: 1; cached: 1'
[IO.File]::WriteAllText((Join-Path $projectDir 'out\first.spv.cache.json'),'{',$utf8)
Check-Build 'Built: 1; cached: 1'
[IO.File]::AppendAllText((Join-Path $projectDir 'out\FirstBindings.pas'),'// changed',$utf8)
Check-Build 'Built: 1; cached: 1'
[IO.File]::WriteAllText((Join-Path $projectDir 'out\first.json'),'{}',$utf8)
Check-Build 'Built: 1; cached: 1'
$hashBefore = (Get-FileHash (Join-Path $projectDir 'out\first.spv')).Hash
[IO.File]::WriteAllText((Join-Path $projectDir 'Util.pasm'),'module Util;',$utf8)
$ambiguity = Invoke-Tool $compiler @('build',$projectPath)
Assert-True ($ambiguity.Code -eq 1 -and $ambiguity.Err -match 'Ambiguous') 'Cache hid a new ambiguous module'
Assert-True ((Get-FileHash (Join-Path $projectDir 'out\first.spv')).Hash -eq $hashBefore) 'Failed preflight changed outputs'
# This is a generated fixture owned by this test, never a source-tree path.
Remove-Item -LiteralPath (Join-Path $projectDir 'Util.pasm')
$config.entries[1].output = 'first.pas'
[IO.File]::WriteAllText($projectPath,($config | ConvertTo-Json -Depth 10),$utf8)
$collision = Invoke-Tool $compiler @('build',$projectPath)
Assert-True ($collision.Code -eq 2 -and $collision.Err -match 'collides') 'Batch outputs may overwrite inputs'
$script:checks += 2
$config['unknown_option'] = $true
[IO.File]::WriteAllText($projectPath,($config | ConvertTo-Json -Depth 10),$utf8)
$unknown = Invoke-Tool $compiler @('build',$projectPath)
Assert-True ($unknown.Code -eq 2 -and $unknown.Err -match 'Unknown project property') 'Project silently accepted an unknown option'
$script:checks++
