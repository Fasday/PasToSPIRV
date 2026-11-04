# Loaded by scripts/test.ps1. Fixtures remain under build/tests/modules.
$moduleCases = Join-Path $cases 'modules'
New-Item -ItemType Directory -Force -Path $moduleCases | Out-Null

function Test-SourceProject(
    [string]$Name,
    [System.Collections.IDictionary]$Files,
    [string]$ExpectedError = '',
    [string[]]$SearchPaths = @(),
    [string]$Location = '',
    [int]$ExpectedCode = 1,
    [string]$WorkingDirectory = '',
    [string[]]$ExtraOptions = @()
) {
    $directory = Join-Path $moduleCases $Name
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    foreach ($key in $Files.Keys) {
        $path = Join-Path $directory $key
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($path)) | Out-Null
        if ($Files[$key] -is [byte[]]) { [IO.File]::WriteAllBytes($path, $Files[$key]) }
        else { [IO.File]::WriteAllText($path, [string]$Files[$key], $utf8) }
    }
    $outputPath = Join-Path $directory 'result.spv'
    $reflection = Join-Path $directory 'result.json'
    $bindings = Join-Path $directory 'ProjectBindings.pas'
    if ($ExpectedError) {
        foreach ($path in @($outputPath, $reflection, $bindings)) {
            [IO.File]::WriteAllText($path, 'keep-existing', $utf8)
        }
    }
    $arguments = @('compile', (Join-Path $directory 'main.pas'), '-o', $outputPath, '--bindings', $bindings)
    foreach ($search in $SearchPaths) { $arguments += @('-I', (Join-Path $directory $search)) }
    $arguments += $ExtraOptions
    $processDirectory = ''
    if ($WorkingDirectory) { $processDirectory = Join-Path $directory $WorkingDirectory }
    $result = Invoke-Tool $compiler $arguments $processDirectory
    if ($ExpectedError) {
        Assert-True ($result.Code -eq $ExpectedCode) "$Name expected error $ExpectedCode, got $($result.Code): $($result.Err)"
        Assert-True ($result.Err -match $ExpectedError) "$Name expected '$ExpectedError': $($result.Err)"
        if ($ExpectedCode -eq 1) {
            Assert-True ($result.Err -match '\(\d+,\d+\): error:') "$Name has no source coordinates"
        }
        if ($Location) { Assert-True ($result.Err -match $Location) "$Name has wrong source origin: $($result.Err)" }
        foreach ($path in @($outputPath, $reflection, $bindings)) {
            Assert-True ([IO.File]::ReadAllText($path) -eq 'keep-existing') "$Name overwrote an artifact on failure"
        }
    }
    else {
        Assert-True ($result.Code -eq 0) "$Name did not compile: $($result.Err)"
        $validation = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.0', $outputPath)
        Assert-True ($validation.Code -eq 0) "$Name has invalid SPIR-V: $($validation.Err)"
        $meta = Get-Content $reflection -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($source in $meta.sources) {
            Assert-True ($source.path -notmatch '^[A-Za-z]:|^/|\\') "$Name leaked an absolute/native source path"
            $actualPath = [IO.Path]::GetFullPath((Join-Path $directory $source.path))
            Assert-True ((Get-FileHash $actualPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $source.sha256) "$Name has wrong raw source hash"
        }
    }
    $script:checks++
    return $directory
}

$simple = Test-SourceProject 'include_simple' @{
    'main.pas' = '{$I ''helper.inc''}' + "`nprocedure Main; var I: Integer; begin I := AddOne(1); end;"
    'helper.inc' = 'function AddOne(V: Integer): Integer; begin Result := V + 1; end;'
}
$meta = Get-Content (Join-Path $simple 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($meta.sources.Count -eq 2 -and $meta.source_dependencies.Count -eq 1) 'Include manifest was not recorded'
$script:checks++

$positiveProjects = @(
    @{ Name = 'include_parentheses'; Files = @{ 'main.pas' = '(*$INCLUDE "helper.inc"*)' + "`nprocedure Main; var I: Integer; begin I := One(); end;"; 'helper.inc' = 'function One: Integer; begin Result := 1; end;' } },
    @{ Name = 'include_nested'; Files = @{ 'main.pas' = '{$I ''sub/outer.inc''}' + "`nprocedure Main; var I: Integer; begin I := Two(); end;"; 'sub/outer.inc' = '{$I inner.inc}' + "`nfunction Two: Integer; begin Result := One() + 1; end;"; 'sub/inner.inc' = 'function One: Integer; begin Result := 1; end;' } },
    @{ Name = 'include_body_repeated'; Files = @{ 'main.pas' = "procedure Main; var I: Integer; begin I := 0;`n" + '{$I body.inc}' + "`n" + '{$I body.inc}' + "`nend;"; 'body.inc' = 'I := I + 1;' } },
    @{ Name = 'include_empty'; Files = @{ 'main.pas' = '{$I empty.inc}' + "`nprocedure Main; begin end;"; 'empty.inc' = '' } },
    @{ Name = 'include_comments'; Files = @{ 'main.pas' = '// {$I missing.inc}' + "`n" + '(* {$I also-missing.inc} *)' + "`nprocedure Main; begin end;" } },
    @{ Name = 'include_bom'; Files = @{ 'main.pas' = '{$I helper.inc}' + "`nprocedure Main; var I: Integer; begin I := One(); end;"; 'helper.inc' = [string][char]0xFEFF + 'function One: Integer; begin Result := 1; end;' } },
    @{ Name = 'include_crlf'; Files = @{ 'main.pas' = '{$I helper.inc}' + "`r`nprocedure Main; var I: Integer; begin I := One(); end;`r`n"; 'helper.inc' = "function One: Integer;`r`nbegin`r`n Result := 1;`r`nend;`r`n" } },
    @{ Name = 'module_diamond'; Files = @{ 'main.pas' = 'uses A, B, Common; procedure Main; var I: Integer; begin I := AValue() + BValue(); end;'; 'A.pasm' = 'module A; uses Common; function AValue: Integer; begin Result := One(); end;'; 'B.pasm' = 'module B; uses Common; function BValue: Integer; begin Result := One() + 1; end;'; 'Common.pasm' = 'module Common; function One: Integer; begin Result := 1; end;' } },
    @{ Name = 'module_case'; Files = @{ 'main.pas' = 'uses util, UTIL; procedure Main; var I: Integer; begin I := One(); end;'; 'Util.pasm' = 'module Util; function One: Integer; begin Result := 1; end;' } },
    @{ Name = 'module_empty'; Files = @{ 'main.pas' = 'uses Empty; procedure Main; begin end;'; 'Empty.pasm' = 'module Empty;' } },
    @{ Name = 'module_records'; Files = @{ 'main.pas' = 'uses Values; var [Binding(0,0)] Data: array of TData; procedure Main; begin Data[0] := Build(); end;'; 'Values.pasm' = 'module Values; type TData = record V: Single3; N: Cardinal; end; function Build: TData; begin Result := Default(TData); Result.N := 7; end;' } },
    @{ Name = 'module_dependency_explicit'; Files = @{ 'main.pas' = 'uses A, B; procedure Main; var I: Integer; begin I := Second(); end;'; 'A.pasm' = 'module A; function First: Integer; begin Result := 1; end;'; 'B.pasm' = 'module B; uses A; function Second: Integer; begin Result := First(); end;' } },
    @{ Name = 'module_unrelated_locals_ab'; Files = @{ 'main.pas' = 'uses A, B; procedure Main; var I: Integer; begin I := Sum(1,2); end;'; 'A.pasm' = 'module A; type X = Cardinal; function Foo: Integer; begin Result := 1; end;'; 'B.pasm' = 'module B; function Sum(X, Foo: Integer): Integer; begin Result := X + Foo; end;' } },
    @{ Name = 'module_unrelated_locals_ba'; Files = @{ 'main.pas' = 'uses B, A; procedure Main; var I: Integer; begin I := Sum(1,2); end;'; 'A.pasm' = 'module A; type X = Cardinal; function Foo: Integer; begin Result := 1; end;'; 'B.pasm' = 'module B; function Sum(X, Foo: Integer): Integer; begin Result := X + Foo; end;' } }
)
foreach ($project in $positiveProjects) { [void](Test-SourceProject $project.Name $project.Files) }
$diamond = Get-Content (Join-Path $moduleCases 'module_diamond\result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (($diamond.modules.name -join ',') -eq 'Common,A,B') 'Modules were not compiled once in dependency order'
$repeat = Get-Content (Join-Path $moduleCases 'include_body_repeated\result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($repeat.sources.Count -eq 2 -and $repeat.source_dependencies.Count -eq 2) 'Textual includes were incorrectly de-duplicated'
$script:checks += 2

$unicodeName = [string][char]0x03A9 + ' math.inc'
$unicodeFiles = @{ 'main.pas' = [string]::Format('{{$I ''{0}''}}', $unicodeName) + "`nprocedure Main; var I: Integer; begin I := One(); end;" }
$unicodeFiles[$unicodeName] = 'function One: Integer; begin Result := 1; end;'
[void](Test-SourceProject 'include_unicode_space' $unicodeFiles)
[void](Test-SourceProject 'include_apostrophe' @{ 'main.pas' = '{$I ''quote''''name.inc''}' + "`nprocedure Main; begin end;"; "quote'name.inc" = '' })
[void](Test-SourceProject 'module_search_path' @{ 'main.pas' = 'uses Util; procedure Main; var I: Integer; begin I := One(); end;'; 'lib/Util.pasm' = 'module Util; function One: Integer; begin Result := 1; end;' } '' @('lib', 'lib/', 'lib\'))
[void](Test-SourceProject 'include_search_path' @{ 'main.pas' = '{$I helper.inc}' + "`nprocedure Main; begin end;"; 'lib/helper.inc' = '' } '' @('lib'))
[void](Test-SourceProject 'no_ambient_working_directory' @{ 'main.pas' = 'uses Ambient; procedure Main; begin end;'; 'cwd/Ambient.pasm' = 'module Ambient;' } 'Dependency not found' -WorkingDirectory 'cwd')
[void](Test-SourceProject 'explicit_relative_search_path' @{ 'main.pas' = 'uses Ambient; procedure Main; begin end;'; 'cwd/lib/Ambient.pasm' = 'module Ambient;' } -WorkingDirectory 'cwd' -ExtraOptions @('--include','lib'))

$badProjects = @(
    @('include_missing', @{ 'main.pas' = '{$I missing.inc}' + "`nprocedure Main; begin end;" }, 'Dependency not found'),
    @('include_inline', @{ 'main.pas' = 'procedure Main; begin {$I body.inc} end;'; 'body.inc' = '' }, 'own line'),
    @('include_trailing_text', @{ 'main.pas' = '{$I body.inc} procedure Main; begin end;'; 'body.inc' = '' }, 'own line'),
    @('include_cycle', @{ 'main.pas' = '{$I a.inc}' + "`nprocedure Main; begin end;"; 'a.inc' = '{$I b.inc}'; 'b.inc' = '{$I a.inc}' }, 'Include cycle'),
    @('include_self', @{ 'main.pas' = '{$I main.pas}' }, 'Include cycle'),
    @('include_repeat_function', @{ 'main.pas' = '{$I helper.inc}' + "`n" + '{$I helper.inc}' + "`nprocedure Main; begin end;"; 'helper.inc' = 'function One: Integer; begin Result := 1; end;' }, 'Duplicate identifier'),
    @('include_absolute', @{ 'main.pas' = '{$I ''C:\missing.inc''}' + "`nprocedure Main; begin end;" }, 'must be relative'),
    @('include_empty_name', @{ 'main.pas' = '{$I ''''}' }, 'filename is empty'),
    @('include_bad_quote', @{ 'main.pas' = '{$I ''file.inc}' }, 'Malformed quoted'),
    @('include_extra_quote_text', @{ 'main.pas' = '{$I ''file.inc'' extra}' }, 'Malformed quoted'),
    @('include_space_unquoted', @{ 'main.pas' = '{$I file name.inc}' }, 'must be quoted'),
    @('include_multiline', @{ 'main.pas' = '{$I file.inc' + "`n}" }, 'Unterminated include'),
    @('include_iocheck', @{ 'main.pas' = '{$I+}' }, 'directives are not supported'),
    @('include_unsupported_directive', @{ 'main.pas' = '{$I file.inc}'; 'file.inc' = '{$DEFINE VALUE}' }, 'directives are not supported'),
    @('include_invalid_utf8', @{ 'main.pas' = '{$I bad.inc}'; 'bad.inc' = [byte[]]@(0xC3,0x28) }, 'valid UTF-8'),
    @('module_missing', @{ 'main.pas' = 'uses Missing; procedure Main; begin end;' }, 'Dependency not found'),
    @('module_name_mismatch', @{ 'main.pas' = 'uses A; procedure Main; begin end;'; 'A.pasm' = 'module Wrong;' }, 'does not match import'),
    @('module_not_delphi_unit', @{ 'main.pas' = 'uses A; procedure Main; begin end;'; 'A.pasm' = 'unit A; interface implementation end.' }, 'Expected module'),
    @('module_as_shader', @{ 'main.pas' = 'module A; function One: Integer; begin Result := 1; end;' }, 'shader entry file'),
    @('module_resources', @{ 'main.pas' = 'uses A; procedure Main; begin end;'; 'A.pasm' = 'module A; var [Binding(0,0)] Data: array of Single;' }, 'only declare types and functions'),
    @('module_main', @{ 'main.pas' = 'uses A; procedure Main; begin end;'; 'A.pasm' = 'module A; procedure Main; begin end;' }, 'only declare types and functions'),
    @('module_empty_types', @{ 'main.pas' = 'uses A; procedure Main; begin end;'; 'A.pasm' = 'module A; type' }, 'at least one type'),
    @('module_duplicate_function', @{ 'main.pas' = 'uses A,B; procedure Main; var I: Integer; begin I := One(); end;'; 'A.pasm' = 'module A; function One: Integer; begin Result := 1; end;'; 'B.pasm' = 'module B; function One: Integer; begin Result := 2; end;' }, 'Ambiguous'),
    @('module_duplicate_type', @{ 'main.pas' = 'uses A,B; procedure Main; var V: TValue; begin end;'; 'A.pasm' = 'module A; type TValue = Cardinal;'; 'B.pasm' = 'module B; type TValue = Integer;' }, 'Ambiguous'),
    @('module_duplicate_kinds_ab', @{ 'main.pas' = 'uses A,B; procedure Main; var I: Integer; begin I := Clash(1); end;'; 'A.pasm' = 'module A; type Clash = Cardinal;'; 'B.pasm' = 'module B; function Clash: Integer; begin Result := 1; end;' }, 'Ambiguous'),
    @('module_duplicate_kinds_ba', @{ 'main.pas' = 'uses B,A; procedure Main; var I: Integer; begin I := Clash(1); end;'; 'A.pasm' = 'module A; type Clash = Cardinal;'; 'B.pasm' = 'module B; function Clash: Integer; begin Result := 1; end;' }, 'Ambiguous'),
    @('module_missing_dependency_function', @{ 'main.pas' = 'uses A,B; procedure Main; begin end;'; 'A.pasm' = 'module A; function First: Integer; begin Result := 1; end;'; 'B.pasm' = 'module B; function Second: Integer; begin Result := First(); end;' }, 'add it to uses'),
    @('module_missing_dependency_type', @{ 'main.pas' = 'uses A,B; procedure Main; begin end;'; 'A.pasm' = 'module A; type TValue = Cardinal;'; 'B.pasm' = 'module B; function Second(V: TValue): Cardinal; begin Result := V; end;' }, 'add it to uses'),
    @('module_missing_dependency_cast', @{ 'main.pas' = 'uses A,B; procedure Main; begin end;'; 'A.pasm' = 'module A; type TValue = Cardinal;'; 'B.pasm' = 'module B; function Second: Cardinal; begin Result := TValue(1); end;' }, 'add it to uses'),
    @('module_late_uses', @{ 'main.pas' = 'uses A; uses B; procedure Main; begin end;'; 'A.pasm' = 'module A;'; 'B.pasm' = 'module B;' }, 'one uses section')
)
foreach ($project in $badProjects) { [void](Test-SourceProject $project[0] $project[1] $project[2]) }
[void](Test-SourceProject 'module_qualified_call' @{ 'main.pas' = 'uses A; procedure Main; var I: Integer; begin I := A.One(); end;'; 'A.pasm' = 'module A; function One: Integer; begin Result := 1; end;' })
$badOrigin = Test-SourceProject 'mapped_include_error' @{ 'main.pas' = '{$I bad.inc}' + "`nprocedure Main; begin end;"; 'bad.inc' = "function FailValue: Integer;`nbegin`n  Missing := 1;`nend;" } 'Unknown identifier' @() 'bad\.inc\(3,3\)'
$unicodeError = @{ 'main.pas' = [string]::Format('{{$I ''{0}''}}', $unicodeName) + "`nprocedure Main; begin end;" }
$unicodeError[$unicodeName] = "function FailValue: Integer;`nbegin`n  Missing := 1;`nend;"
[void](Test-SourceProject 'mapped_unicode_error' $unicodeError 'Unknown identifier' @() ([regex]::Escape($unicodeName) + '\(3,3\)'))
[void](Test-SourceProject 'mapped_root_after_include' @{ 'main.pas' = '{$I helper.inc}' + "`nprocedure Main;`nbegin`n  Missing := 1;`nend;"; 'helper.inc' = "function One: Integer;`nbegin`n Result := 1;`nend;`n" } 'Unknown identifier' @() 'main\.pas\(4,3\)')
[void](Test-SourceProject 'mapped_module_error' @{ 'main.pas' = 'uses A; procedure Main; begin end;'; 'A.pasm' = "module A;`nfunction FailValue: Integer;`nbegin`n  Missing := 1;`nend;" } 'Unknown identifier' @() 'A\.pasm\(4,3\)')
[void](Test-SourceProject 'module_cycle' @{ 'main.pas' = 'uses A; procedure Main; begin end;'; 'A.pasm' = "module A;`nuses B;"; 'B.pasm' = "module B;`nuses A;" } 'Module cycle' @() 'B\.pasm\(2,6\)')
[void](Test-SourceProject 'module_ambiguous' @{ 'main.pas' = 'uses A; procedure Main; begin end;'; 'left/A.pasm' = 'module A;'; 'right/A.pasm' = 'module A;' } 'Ambiguous dependency' @('left','right'))
[void](Test-SourceProject 'include_ambiguous' @{ 'main.pas' = '{$I helper.inc}'; 'helper.inc' = ''; 'lib/helper.inc' = '' } 'Ambiguous dependency' @('lib'))
[void](Test-SourceProject 'module_conflicting_files' @{ 'main.pas' = 'uses LeftModule, RightModule; procedure Main; begin end;'; 'LeftModule.pasm' = 'module LeftModule;' + "`n" + '{$I left/uses.inc}'; 'RightModule.pasm' = 'module RightModule;' + "`n" + '{$I right/uses.inc}'; 'left/uses.inc' = 'uses Util;'; 'right/uses.inc' = 'uses Util;'; 'left/Util.pasm' = 'module Util;'; 'right/Util.pasm' = 'module Util;' } 'Conflicting files')
[void](Test-SourceProject 'missing_search_directory' @{ 'main.pas' = 'procedure Main; begin end;' } 'directory does not exist' @('missing') '' 2)

$includeDepthFiles = @{ 'main.pas' = '{$I f0.inc}' + "`nprocedure Main; begin end;" }
foreach ($i in 0..65) { $includeDepthFiles["f$i.inc"] = if ($i -eq 65) { '' } else { '{$I f' + ($i + 1) + '.inc}' } }
[void](Test-SourceProject 'include_depth' $includeDepthFiles 'Include nesting limit')
$moduleDepthFiles = @{ 'main.pas' = 'uses M0; procedure Main; begin end;' }
foreach ($i in 0..65) { $moduleDepthFiles["M$i.pasm"] = "module M$i; " + $(if ($i -eq 65) { '' } else { 'uses M' + ($i + 1) + ';' }) }
[void](Test-SourceProject 'module_depth' $moduleDepthFiles 'Module nesting limit')
$tooManyImports = 'uses ' + ((1..4097 | ForEach-Object { 'A' }) -join ',') + '; procedure Main; begin end;'
[void](Test-SourceProject 'import_budget' @{ 'main.pas' = $tooManyImports; 'A.pasm' = 'module A;' } '4096 imports')
[void](Test-SourceProject 'raw_source_budget' @{ 'main.pas' = (New-Object byte[] (8 * 1024 * 1024 + 1)) } '8 MiB')
$fileBudget = @{ 'main.pas' = ((1..512 | ForEach-Object { '{$I f' + $_ + '.inc}' }) -join "`n") + "`nprocedure Main; begin end;" }
foreach ($i in 1..512) { $fileBudget["f$i.inc"] = '' }
[void](Test-SourceProject 'source_file_budget' $fileBudget 'file limit')
$expandedSource = ((1..9 | ForEach-Object { '{$I large.inc}' }) -join "`n") + "`nprocedure Main; begin end;"
[void](Test-SourceProject 'expanded_character_budget' @{ 'main.pas' = $expandedSource; 'large.inc' = '{' + ('a' * (1024 * 1024)) + '}' } 'Expanded source')
$expandedLines = ((1..25 | ForEach-Object { '{$I lines.inc}' }) -join "`n") + "`nprocedure Main; begin end;"
[void](Test-SourceProject 'expanded_line_budget' @{ 'main.pas' = $expandedLines; 'lines.inc' = "// padding`n" * 10000 } 'Expanded source')

$moduleOutput = Join-Path $moduleCases 'common.spv'
$common = Invoke-Tool $compiler @((Join-Path $root 'examples\modules_compute.pas'), '-I', (Join-Path $root 'examples\modules'), '-o', $moduleOutput)
Assert-True ($common.Code -eq 0) "Common-source example failed: $($common.Err)"
$commonValidation = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.0', $moduleOutput)
Assert-True ($commonValidation.Code -eq 0) "Common-source SPIR-V is invalid: $($commonValidation.Err)"
$commonMeta = Get-Content ([IO.Path]::ChangeExtension($moduleOutput, '.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (($commonMeta.modules.name -join ',') -eq 'SharedTypes,SharedBits,SharedMath') 'Common module order is incorrect'
foreach ($source in $commonMeta.sources) {
    $actualPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'examples') $source.path))
    Assert-True ((Get-FileHash $actualPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $source.sha256) 'Example dependency hash is incorrect'
}
$script:checks++

# A different checkout root must not affect the SPIR-V, manifest or bindings.
$relocated = Test-SourceProject 'relocated_include' @{ 'main.pas' = [IO.File]::ReadAllText((Join-Path $simple 'main.pas')); 'helper.inc' = [IO.File]::ReadAllText((Join-Path $simple 'helper.inc')) }
foreach ($file in @('result.spv', 'result.json', 'ProjectBindings.pas')) {
    Assert-True ((Get-FileHash (Join-Path $simple $file)).Hash -eq (Get-FileHash (Join-Path $relocated $file)).Hash) "Relocation changed $file"
}
$script:checks++

# Reproducibility also covers a diamond module graph, not just textual includes.
$diamondFiles = @{}
foreach ($name in @('main.pas','A.pasm','B.pasm','Common.pasm')) {
    $diamondFiles[$name] = [IO.File]::ReadAllText((Join-Path (Join-Path $moduleCases 'module_diamond') $name))
}
$diamondCopy = Test-SourceProject 'relocated_modules' $diamondFiles
foreach ($file in @('result.spv','result.json','ProjectBindings.pas')) {
    Assert-True ((Get-FileHash (Join-Path (Join-Path $moduleCases 'module_diamond') $file)).Hash -eq (Get-FileHash (Join-Path $diamondCopy $file)).Hash) "Module relocation changed $file"
}
$script:checks++

if (-not $SkipDelphiTests) {
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\SourceAPICheck.dpr')
    $api = Invoke-Tool (Join-Path $root 'build\bin\SourceAPICheck.exe') @((Join-Path $root 'examples\modules_compute.pas'), (Join-Path $root 'examples\modules'), (Join-Path $badOrigin 'main.pas'))
    Assert-True ($api.Code -eq 0 -and $api.Out -match 'PASS:') "Source API checks failed: $($api.Err)"
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\SharedSourceCheck.dpr')
    $inputBytes = [byte[]]@(0,0,0,0, 1,0,0,0, 255,255,255,255)
    $cpuInput = Join-Path $moduleCases 'cpu-input.bin'
    $cpuOutput = Join-Path $moduleCases 'cpu-output.bin'
    [IO.File]::WriteAllBytes($cpuInput, $inputBytes)
    $cpu = Invoke-Tool (Join-Path $root 'build\bin\SharedSourceCheck.exe') @('integer', $cpuInput, $cpuOutput, '0')
    Assert-True ($cpu.Code -eq 0 -and (Get-FileHash $cpuInput).Hash -eq (Get-FileHash $cpuOutput).Hash) "Delphi common-source zero-round test failed: $($cpu.Err)"
    $script:checks += 2
}
else { Write-Warning 'Delphi source API and common CPU reference checks were explicitly skipped (-SkipDelphiTests).' }
