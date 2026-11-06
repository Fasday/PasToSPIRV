param(
    [string]$DelphiRoot = $env:BDS,
    [string]$Project,
    # Optional .rc scripts, compiled with Delphi's cgrc into build\res\<name>.res first.
    [string[]]$Resources = @(),
    # Isolate test/demo builds from executables which the user may have open.
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Project) { $Project = Join-Path $root 'source\PasToSPIRV.dpr' }
$Project = [IO.Path]::GetFullPath($Project)

if (-not $DelphiRoot) {
    $registryPaths = @(
        'HKCU:\Software\Embarcadero\BDS',
        'HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS',
        'HKLM:\SOFTWARE\Embarcadero\BDS'
    )
    $installations = foreach ($path in $registryPaths) {
        if (Test-Path $path) {
            Get-ChildItem $path | ForEach-Object { Get-ItemProperty $_.PSPath }
        }
    }
    $installation = $installations |
        Where-Object { $_.RootDir -and (Test-Path (Join-Path $_.RootDir 'bin\dcc64.exe')) } |
        Sort-Object { [version]$_.PSChildName } -Descending |
        Select-Object -First 1
    if ($installation) {
        $DelphiRoot = $installation.RootDir
    }
}

if (-not $DelphiRoot) {
    throw 'Delphi was not found. Pass -DelphiRoot or set BDS to the Delphi installation directory.'
}

$compiler = Join-Path $DelphiRoot 'bin\dcc64.exe'
$library = Join-Path $DelphiRoot 'lib\win64\release'
$output = Join-Path $root 'build\bin'
if ($OutputDirectory) { $output = [IO.Path]::GetFullPath($OutputDirectory) }
$units = Join-Path $root 'build\dcu'
New-Item -ItemType Directory -Force -Path $output, $units | Out-Null

foreach ($resource in $Resources) {
    $script = (Resolve-Path $resource).Path
    $resourceOutput = Join-Path $root 'build\res'
    $target = Join-Path $resourceOutput ([IO.Path]::GetFileNameWithoutExtension($script) + '.res')
    New-Item -ItemType Directory -Force -Path $resourceOutput | Out-Null
    # File names inside the script are resolved relative to its directory.
    Push-Location ([IO.Path]::GetDirectoryName($script))
    try {
        $log = & (Join-Path $DelphiRoot 'bin\cgrc.exe') "-fo$target" $script 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Resource compilation of $script failed (exit code $LASTEXITCODE): $log"
        }
    }
    finally { Pop-Location }
}

Push-Location ([IO.Path]::GetDirectoryName($Project))
try {
    & $compiler '-B' '-Q' '-W+' '-H+' "-U$library;$root\source" "-N0$units" "-E$output" $Project
    if ($LASTEXITCODE -ne 0) {
        throw "Delphi compilation failed (exit code $LASTEXITCODE)."
    }
}
finally { Pop-Location }

Write-Host "Built: $(Join-Path $output ([IO.Path]::GetFileNameWithoutExtension($Project) + '.exe'))"
