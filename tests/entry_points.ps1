# External entry-point names: CLI, .pasm entry files/imports, reflection and cache.
$entryDir = Join-Path $cases 'entry-points'
New-Item -ItemType Directory -Force -Path $entryDir | Out-Null
$entrySource = Join-Path $entryDir 'shader.pasm'
[IO.File]::WriteAllText((Join-Path $entryDir 'EntryMath.pasm'),
    'module EntryMath; function Value(I: Cardinal): Cardinal; begin Result := I * 3 + 7; end;', $utf8)
[IO.File]::WriteAllText($entrySource,
    'uses EntryMath; var [Binding(0,0)] Data: array of Cardinal; procedure Main; begin Data[GlobalInvocationID.X] := Value(GlobalInvocationID.X); end;', $utf8)
$entryOutput = Join-Path $entryDir 'shader.spv'
$entryReflection = Join-Path $entryDir 'shader.json'
$entryBindings = Join-Path $entryDir 'EntryBindings.pas'

function Check-EntryArtifact([string]$Output, [string]$Name, [string]$Environment = 'vulkan1.0') {
    $validation = Invoke-Tool $SpirvVal @('--target-env', $Environment, $Output)
    Assert-True ($validation.Code -eq 0) "Entry-point SPIR-V invalid: $($validation.Err)"
    $assembly = Invoke-Tool $SpirvDis @($Output)
    Assert-True ($assembly.Code -eq 0) 'Entry-point disassembly failed'
    Assert-True ($assembly.Out -cmatch ('OpEntryPoint GLCompute %\S+ "' + [regex]::Escape($Name) + '"')) 'SPIR-V entry-point name/case mismatch'
    Assert-True (([regex]::Matches($assembly.Out, '\bOpEntryPoint\b')).Count -eq 1) 'Expected exactly one entry point'
    $metadata = Get-Content ([IO.Path]::ChangeExtension($Output, '.json')) -Raw | ConvertFrom-Json
    Assert-True ($metadata.entry_point -ceq $Name) 'Reflection entry-point name/case mismatch'
    Assert-True (($metadata.local_size -join ',') -eq '64,1,1') 'Renaming changed local size'
    $script:checks++
}

foreach ($name in @('Main', 'main', 'Kernel_42', '_', 'begin', ('K' * 127))) {
    foreach ($mode in @('-O0', '-O1')) {
        $options = @('compile', $entrySource, '-o', $entryOutput, '--bindings', $entryBindings, $mode)
        # Default and explicit Main must be identical; keywords are allowed as external names.
        if ($name -cne 'Main') { $options += @('--entry-point', $name) }
        $run = Invoke-Tool $compiler $options
        Assert-True ($run.Code -eq 0) "Entry-point compile failed: $($run.Err)"
        Check-EntryArtifact $entryOutput $name
        Assert-True ([IO.File]::ReadAllText($entryBindings) -match 'unit EntryBindings;') 'Entry-point option broke bindings'
    }
}
$defaultRun = Invoke-Tool $compiler @($entrySource, '-o', $entryOutput)
Assert-True ($defaultRun.Code -eq 0) 'Default entry compile failed'
$defaultHash = (Get-FileHash $entryOutput).Hash
$explicitRun = Invoke-Tool $compiler @('--entry-point', 'Main', $entrySource, '-o', $entryOutput)
Assert-True ($explicitRun.Code -eq 0 -and (Get-FileHash $entryOutput).Hash -eq $defaultHash) 'Explicit Main changed the default SPIR-V'
$script:checks++

# Bad options must not touch any artifacts (including non-ASCII/quoted names).
# NUL cannot be passed through Windows argv; it is covered by the API tests.
$badEntryArgs = @(
    @{ Args = @('--entry-point'); Error = 'missing name' },
    @{ Args = @('--entry-point', ''); Error = 'missing name' },
    @{ Args = @('--entry-point', '-O1'); Error = 'missing name' },
    @{ Args = @('--entry-point', 'main', '--entry-point', 'other'); Error = 'duplicate --entry-point' }
)
foreach ($bad in @('1main', 'bad name', 'bad-name', 'A.B', 'a/b', "a`nb", 'a"b', ([string][char]0x03BB), ('K' * 128))) {
    $badEntryArgs += @{ Args = @('--entry-point', $bad); Error = 'Entry-point name' }
}
foreach ($bad in $badEntryArgs) {
    foreach ($path in @($entryOutput, $entryReflection, $entryBindings)) { [IO.File]::WriteAllText($path, 'keep', $utf8) }
    $run = Invoke-Tool $compiler (@($entrySource, '-o', $entryOutput, '--bindings', $entryBindings) + $bad.Args)
    Assert-True ($run.Code -eq 2 -and $run.Err -match $bad.Error) "Bad entry-point option accepted: $($run.Err)"
    foreach ($path in @($entryOutput, $entryReflection, $entryBindings)) {
        Assert-True ([IO.File]::ReadAllText($path) -eq 'keep') 'Invalid entry-point option overwrote an output'
    }
    $script:checks++
}

# External naming does not rename the Pascal procedure or make Main callable.
$wrongSource = Join-Path $entryDir 'wrong.pasm'
[IO.File]::WriteAllText($wrongSource, 'procedure Kernel; begin end;', $utf8)
$run = Invoke-Tool $compiler @($wrongSource, '--entry-point', 'Kernel', '-o', $entryOutput)
Assert-True ($run.Code -eq 1) 'External name selected a different source procedure'
$script:checks++

$projectPath = Join-Path $entryDir 'project.json'
$projectOut = Join-Path $entryDir 'out\first.spv'
$config = @{ format_version = 1; entries = @(
    @{ source = 'shader.pasm'; output = 'out/first.spv'; entry_point = 'main' },
    @{ source = 'shader.pasm'; output = 'out/second.spv' }
) }
function Invoke-EntryBuild([string]$Expected, [switch]$Force) {
    [IO.File]::WriteAllText($projectPath, ($config | ConvertTo-Json -Depth 10), $utf8)
    $options = @('build', $projectPath)
    if ($Force) { $options += '--force' }
    $run = Invoke-Tool $compiler $options
    Assert-True ($run.Code -eq 0 -and $run.Out -match $Expected) "Entry project failed: $($run.Out)$($run.Err)"
    $script:checks++
}
Invoke-EntryBuild 'Built: 2; cached: 0' -Force
Check-EntryArtifact $projectOut 'main'
Check-EntryArtifact (Join-Path $entryDir 'out\second.spv') 'Main'
Invoke-EntryBuild 'Built: 0; cached: 2'
$config.entries[0].entry_point = 'Main' # Case alone must invalidate only this entry.
Invoke-EntryBuild 'Built: 1; cached: 1'
Check-EntryArtifact $projectOut 'Main'
Invoke-EntryBuild 'Built: 0; cached: 2'
$config.entries[0].Remove('entry_point') # Omitted Main and explicit Main share a cache key.
Invoke-EntryBuild 'Built: 0; cached: 2'

# Validate every name during preflight, before an earlier entry can write outputs.
$config.entries[0].entry_point = 'Changed'
$projectHash = (Get-FileHash $projectOut).Hash
foreach ($bad in @('', '1bad', 'bad name', ('K' * 128), $null, 42, $true)) {
    $config.entries[1].entry_point = $bad
    [IO.File]::WriteAllText($projectPath, ($config | ConvertTo-Json -Depth 10), $utf8)
    $run = Invoke-Tool $compiler @('build', $projectPath, '--force')
    Assert-True ($run.Code -eq 2) 'Invalid project entry_point was accepted'
    Assert-True ((Get-FileHash $projectOut).Hash -eq $projectHash) 'Invalid project entry_point was not preflighted'
    $script:checks++
}

# Execution modes use the same function ID regardless of the external name/profile.
$extendedSource = Join-Path $entryDir 'extended.pasm'
[IO.File]::WriteAllText($extendedSource, '[Vulkan12, StrictFloat] procedure Main; var D: Double; begin D := 1.0d; end;', $utf8)
foreach ($mode in @('-O0', '-O1')) {
    $run = Invoke-Tool $compiler @($extendedSource, '--entry-point', 'main', '-o', $entryOutput, $mode)
    Assert-True ($run.Code -eq 0) "Extended renamed entry failed: $($run.Err)"
    Check-EntryArtifact $entryOutput 'main' 'vulkan1.2'
}
