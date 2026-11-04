param([switch]$Probe)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $root ('build\audit\file-links-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$encoding = New-Object Text.UTF8Encoding($false)
$compiler = Join-Path $root 'build\bin\PasToSPIRV.exe'

function Run-Compiler([string[]]$Arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $compiler
    $info.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $info
    try {
        [void]$p.Start()
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'Compiler probe timed out' }
        return [pscustomobject]@{ Code=$p.ExitCode; Out=$out.GetAwaiter().GetResult(); Err=$err.GetAwaiter().GetResult() }
    }
    finally { $p.Dispose() }
}

$shader = 'procedure Main; begin end;'
$caseDir = Join-Path $directory 'hardlink'
New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
$source = Join-Path $caseDir 'shader.pas'
$output = Join-Path $caseDir 'output.spv'
[IO.File]::WriteAllText($source,$shader,$encoding)
New-Item -ItemType HardLink -Path $output -Value $source | Out-Null
$r = Run-Compiler @($source,'-o',$output)
$preserved = [IO.File]::ReadAllText($source) -eq $shader
Write-Host "compile-hardlink: code=$($r.Code), source-preserved=$preserved"
if (-not $Probe -and ($r.Code -ne 2 -or -not $preserved)) { throw 'Compile output may overwrite a hard-linked source' }

$caseDir = Join-Path $directory 'junction'
$real = Join-Path $caseDir 'real'
$alias = Join-Path $caseDir 'alias'
New-Item -ItemType Directory -Force -Path $real | Out-Null
$source = Join-Path $real 'shader.pas'
[IO.File]::WriteAllText($source,$shader,$encoding)
New-Item -ItemType Junction -Path $alias -Value $real | Out-Null
$r = Run-Compiler @($source,'-o',(Join-Path $alias 'shader.pas'))
$preserved = [IO.File]::ReadAllText($source) -eq $shader
Write-Host "compile-junction: code=$($r.Code), source-preserved=$preserved"
if (-not $Probe -and ($r.Code -ne 2 -or -not $preserved)) { throw 'Compile output may overwrite a source through a directory alias' }
$destination = Join-Path $real 'new-output.spv'
$r = Run-Compiler @($source,'-o',$destination,'--reflection',(Join-Path $alias 'new-output.spv'))
Write-Host "output-junction-alias: code=$($r.Code), artifact-created=$(Test-Path $destination)"
if (-not $Probe -and ($r.Code -ne 2 -or (Test-Path $destination))) { throw 'Distinct output names may alias one physical destination' }

$caseDir = Join-Path $directory 'batch'
New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
$source = Join-Path $caseDir 'shader.pas'
$output = Join-Path $caseDir 'output.spv'
[IO.File]::WriteAllText($source,$shader,$encoding)
New-Item -ItemType HardLink -Path $output -Value $source | Out-Null
$project = @{ format_version=1; entries=@(@{source='shader.pas'; output='output.spv'}) }
$projectPath = Join-Path $caseDir 'project.json'
[IO.File]::WriteAllText($projectPath,($project | ConvertTo-Json -Depth 6),$encoding)
$r = Run-Compiler @('build',$projectPath,'--force')
$preserved = [IO.File]::ReadAllText($source) -eq $shader
Write-Host "batch-hardlink: code=$($r.Code), source-preserved=$preserved"
if (-not $Probe -and ($r.Code -ne 2 -or -not $preserved)) { throw 'Batch output may overwrite a hard-linked source' }

# Duplicate future outputs through a directory junction must be caught before any write.
$caseDir = Join-Path $directory 'batch-alias'
$real = Join-Path $caseDir 'real'
$alias = Join-Path $caseDir 'alias'
New-Item -ItemType Directory -Force -Path $real | Out-Null
New-Item -ItemType Junction -Path $alias -Value $real | Out-Null
[IO.File]::WriteAllText((Join-Path $caseDir 'shader.pas'),$shader,$encoding)
$project = @{format_version=1; entries=@(@{source='shader.pas';output='real/new.spv'},@{source='shader.pas';output='alias/new.spv'})}
$projectPath = Join-Path $caseDir 'project.json'
[IO.File]::WriteAllText($projectPath,($project | ConvertTo-Json -Depth 6),$encoding)
$r = Run-Compiler @('build',$projectPath,'--force')
Write-Host "batch-output-alias: code=$($r.Code), artifact-created=$(Test-Path (Join-Path $real 'new.spv'))"
if (-not $Probe -and ($r.Code -ne 2 -or (Test-Path (Join-Path $real 'new.spv')))) { throw 'Batch preflight misses canonical destination aliases' }
if (-not $Probe) { Write-Host 'PASS: source/output identity protection (hard links and directory junctions).' }
