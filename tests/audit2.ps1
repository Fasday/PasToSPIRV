# Regressions for the second independent audit (1.0.2). Loaded by scripts/test.ps1.
$long127 = 'a' * 127
$frontendFailures = @(
    @('a2_const_attr_resource', 'var [PushConstant] P: record Count: Cardinal; end; [LocalSize(P.Count,1,1)] procedure Main; begin end;', 'Constant expressions cannot read'),
    @('a2_const_binding_resource', 'var [Binding(0,0)] A: array of Cardinal; [Binding(0, A[0])] B: array of Cardinal; procedure Main; begin end;', 'Constant expressions cannot read'),
    @('a2_const_bound_resource', 'var [Binding(0,0)] A: array of Cardinal; [Binding(0,1)] B: array of array[0..A[0]] of Cardinal; procedure Main; begin end;', 'Constant expressions cannot read'),
    @('a2_clamp_mixed_signedness', 'var [Binding(0,0)] D: array of Cardinal; [Binding(0,1)] I0: array of Integer; procedure Main; var U: Cardinal; I: Integer; begin U := D[0]; I := I0[0]; I0[1] := Clamp(5, U, I); end;', 'Cannot convert|common numeric type'),
    @('a2_clamp_mixed_reverse', 'var [Binding(0,0)] D: array of Cardinal; [Binding(0,1)] I0: array of Integer; procedure Main; var U: Cardinal; I: Integer; begin U := D[0]; I := I0[0]; D[1] := Clamp(5, I, U); end;', 'Cannot convert|common numeric type'),
    @('a2_cast_keeps_type_compare', 'var [Binding(0,0)] R: array of Cardinal; [Binding(0,1)] I0: array of Integer; procedure Main; var I: Integer; begin I := I0[0]; if Cardinal(1) > I then R[0] := 1; end;', 'Cannot convert'),
    @('a2_cast_keeps_type_div', 'var [Binding(0,0)] F: array of Single; [Binding(0,1)] I0: array of Integer; procedure Main; var I: Integer; begin I := I0[0]; F[0] := Cardinal(10) div I; end;', 'Cannot convert'),
    @('a2_cast_same_type_fixed', 'procedure Main; var U: Cardinal; begin U := Integer(5); end;', 'Cannot convert'),
    @('a2_typed_const_keeps_type', 'const C: Integer = 5; procedure Main; var U: Cardinal; begin U := C; end;', 'Cannot convert'),
    @('a2_while_backedge', 'var [Binding(0,0)] D: array of Cardinal; procedure Main; var J: Integer; begin J := 0; while J < 10 do for J := 0 to 3 do D[1] := 1; end;', 'uninitialized'),
    @('a2_for_backedge', 'var [Binding(0,0)] D: array of Integer; procedure Main; var I: Integer; J: Integer; begin J := 0; for I := 0 to 3 do begin D[I] := J; for J := 0 to 3 do D[0] := 1; end; end;', 'uninitialized'),
    @('a2_for_bound_backedge', 'var [Binding(0,0)] D: array of Integer; procedure Main; var I: Integer; J: Integer; begin J := 0; for I := 0 to 3 do for J := J to 3 do D[0] := 1; end;', 'uninitialized'),
    @('a2_partial_write_backedge', 'type T = record V: Integer; end; procedure Main; var R: T; I: Integer; K: Integer; begin R := Default(T); K := 0; while K < 2 do begin R.V := I; for I := 0 to 1 do K := K + 1; end; end;', 'uninitialized'),
    @('a2_negative_buffer_index', 'const N = -1; var [Binding(0,0)] D: array of Cardinal; procedure Main; begin D[N] := 1; end;', 'out of bounds'),
    @('a2_min_integer_buffer_index', 'var [Binding(0,0)] D: array of Cardinal; procedure Main; begin D[-2147483648] := 1; end;', 'out of bounds'),
    @('a2_folded_negative_index', 'type TA = array[0..3] of Integer; var [Binding(0,0)] D: array of Integer; procedure Main; var A: TA; begin A := Default(TA); D[0] := A[0 - 1]; end;', 'out of bounds'),
    @('a2_folded_high_index', 'type TA = array[0..3] of Integer; var [Binding(0,0)] D: array of Integer; procedure Main; var A: TA; begin A := Default(TA); D[0] := A[2 * 2]; end;', 'out of bounds'),
    @('a2_empty_global_var', "var`nprocedure Main; begin end;", 'at least one resource'),
    @('a2_identifier_128', "procedure Main; var $('a' * 128): Integer; begin end;", '127 characters'),
    @('a2_literal_overflow', 'var [Binding(0,0)] F: array of Single; procedure Main; begin F[0] := 3.4028236e38; end;', 'finite Single range')
)
foreach ($case in $frontendFailures) { Test-Failure $case[0] $case[1] $case[2] }
Test-Failure 'a2_nul_in_comment' ("procedure Main; begin end;`n{ a " + [char]0 + ' b }') 'NUL'

$frontendSuccesses = @(
    @('a2_typed_const_left', 'const Big: Cardinal = $7FFFFFFF; var [Binding(0,0)] R: array of Cardinal; [Binding(0,1)] F: array of Single; procedure Main; begin if Big + 1 > 0 then R[0] := 1; if 1 + Big > 0 then R[1] := 1; F[0] := Big + 1; end;'),
    @('a2_typed_const_operand_order', 'const Half: Cardinal = 1000000000; procedure Main; var X: Cardinal; begin X := Half * 3; X := 3 * Half; end;'),
    @('a2_untyped_const_adapts', 'const N = 3; M = N + 4; procedure Main; var U: Cardinal; begin U := 1; U := U + N + M; end;'),
    @('a2_valid_nested_loops', 'var [Binding(0,0)] D: array of Integer; procedure Main; var I: Integer; J: Integer; begin J := 0; while J < 10 do begin for I := 0 to 3 do D[I] := J; J := J + 1; end; end;'),
    @('a2_flt_max_literal', 'var [Binding(0,0)] F: array of Single; procedure Main; begin F[0] := 3.4028235e38; F[1] := -3.4028235e38; F[2] := 0e999999999999; F[3] := 1e-999999999; end;'),
    @('a2_cardinal_truncation', 'const C = Cardinal(-0.5); D = Integer(-0.9); var [Binding(0,0)] R: array of Cardinal; procedure Main; begin R[0] := C + Cardinal(D); end;'),
    @('a2_identifier_127', "procedure Main; var ${long127}: Integer; begin ${long127} := 1; end;"),
    @('a2_shared_type_in_buffer', 'type TS = array[0..63] of Cardinal; var [Binding(0,0)] Data: array of TS; [Shared] S: TS; [LocalSize(64,1,1)] procedure Main; var L: TS; begin S[LocalInvocationIndex] := 1; Barrier; L := S; if LocalInvocationIndex = 0 then begin Data[1] := L; S := Data[2]; end; end;'),
    @('a2_shared_type_in_push', 'type TS = array[0..3] of Cardinal; var [PushConstant] P: record V: TS; end; [Shared] S: TS; [LocalSize(4,1,1)] procedure Main; begin S := P.V; end;'),
    @('a2_shared_alias_record', 'type TS = array[0..7] of Integer; TAlias = TS; TR = record A: TAlias; end; var [Binding(0,0)] D: array of TR; [Shared] S: TAlias; [LocalSize(8,1,1)] procedure Main; begin S[LocalInvocationIndex] := 0; Barrier; D[0].A := S; end;')
)
foreach ($case in $frontendSuccesses) { Test-Success $case[0] $case[1] }
$assembly = Invoke-Tool $SpirvDis @((Join-Path $cases 'a2_typed_const_left.spv'))
Assert-True ($assembly.Out -match '\bOpUGreaterThan\b' -and $assembly.Out -notmatch '\bOpSGreaterThan\b' -and
    $assembly.Out -match '\bOpConvertUToF\b') 'Typed Cardinal constant was retyped by operand order'
$script:checks++

[void](Test-SourceProject 'a2_reserved_module_builtin' @{ 'main.pas' = 'uses GlobalInvocationID; procedure Main; begin end;'; 'GlobalInvocationID.pasm' = 'module GlobalInvocationID; const X = 7;' } 'reserved identifiers')
[void](Test-SourceProject 'a2_reserved_module_type' @{ 'main.pas' = 'uses Integer; procedure Main; begin end;'; 'Integer.pasm' = 'module Integer;' } 'reserved identifiers')
[void](Test-SourceProject 'a2_invalid_include_chars' @{ 'main.pas' = "{`$I 'a<b.inc'}`nprocedure Main; begin end;" } 'Invalid dependency path')

# S-1: repeated includes are memoised; edges are recorded once per directive.
$expFiles = @{ 'main.pas' = "{`$I f0.inc}`nprocedure Main; begin end;"; 'empty.inc' = '' }
foreach ($k in 0..39) { $next = if ($k -eq 39) { 'empty.inc' } else { "f$($k + 1).inc" }; $expFiles["f$k.inc"] = "{`$I $next}`n{`$I $next}" }
$watch = [Diagnostics.Stopwatch]::StartNew()
$expDir = Test-SourceProject 'a2_exponential_includes' $expFiles
$watch.Stop()
$meta = Get-Content (Join-Path $expDir 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($watch.Elapsed.TotalSeconds -lt 20 -and $meta.source_dependencies.Count -eq 81) "Include expansion is not linear: $($watch.Elapsed.TotalSeconds) s, $($meta.source_dependencies.Count) edges"
$script:checks++

# S-8: exact line budget boundaries.
[void](Test-SourceProject 'a2_line_budget_exact' @{ 'main.pas' = ("procedure Main; begin end;`n" + ("//`n" * 199999)) })
[void](Test-SourceProject 'a2_line_budget_over' @{ 'main.pas' = ("procedure Main; begin end;`n" + ("//`n" * 200000)) } 'line budget|Expanded source')

# S-7: one directory spelled with different non-ASCII case is not ambiguous.
$upper = [string][char]0xDC + 'mods'
$lower = [string][char]0xFC + 'mods'
$s7 = @{ 'main.pas' = "{`$I x.inc}`nprocedure Main; begin end;" }
$s7["$upper\x.inc"] = ''
[void](Test-SourceProject 'a2_unicode_case_directory' $s7 '' @($upper, $lower))

# CLI and batch output safety.
$cli = Join-Path $cases 'a2-cli'
New-Item -ItemType Directory -Force $cli | Out-Null
$shader = Join-Path $cli 'a.pas'
[IO.File]::WriteAllText($shader, 'procedure Main; begin end;', $utf8)
$victim = Join-Path $cli 'victim.txt'
[IO.File]::WriteAllText($victim, 'keep', $utf8)
$empty = Invoke-Tool $compiler @('compile', $shader, '-o', '', $victim)
Assert-True ($empty.Code -eq 2 -and [IO.File]::ReadAllText($victim) -eq 'keep') 'An empty option value shifted the next argument'
$alias = Invoke-Tool $compiler @($shader, '-o', (Join-Path $cli "$([char]0xC4).spv"), '--reflection', (Join-Path $cli "$([char]0xE4).spv"))
Assert-True ($alias.Code -eq 2 -and -not (Test-Path (Join-Path $cli "$([char]0xC4).spv"))) 'Unicode case aliases of one new output were accepted'
$ads = Invoke-Tool $compiler @($shader, '-o', (Join-Path $cli 'o.spv'), '--reflection', (Join-Path $cli 'o.spv:stream'))
Assert-True ($ads.Code -eq 2 -and -not (Test-Path (Join-Path $cli 'o.spv'))) 'Alternate data stream output was accepted'
$missing = Invoke-Tool $compiler @((Join-Path $cli 'missing.pas'))
Assert-True ($missing.Code -eq 2 -and $missing.Err -match 'Input file not found') 'Missing input diagnostic is unclear'
$script:checks += 4
$share = '\\localhost\' + $cli.Substring(0, 1) + '$' + $cli.Substring(2)
if (Test-Path $share) {
    $unc = Invoke-Tool $compiler @($shader, '-o', (Join-Path $cli 'c.spv'), '--reflection', (Join-Path $share 'c.spv'))
    Assert-True ($unc.Code -eq 2 -and -not (Test-Path (Join-Path $cli 'c.spv'))) 'Loopback UNC alias of a new output was accepted'
    $project = @{ format_version = 1; entries = @(@{ source = 'a.pas'; output = 'u/n.spv' }, @{ source = 'a.pas'; output = (Join-Path $share 'u\n.spv') }) }
    $projectPath = Join-Path $cli 'unc.json'
    [IO.File]::WriteAllText($projectPath, ($project | ConvertTo-Json -Depth 6), $utf8)
    $build = Invoke-Tool $compiler @('build', $projectPath, '--force')
    Assert-True ($build.Code -eq 2 -and -not (Test-Path (Join-Path $cli 'u\n.spv'))) 'Batch accepted UNC aliases of one new output'
    $script:checks += 2
}
else { Write-Warning 'Loopback administrative share is unavailable; UNC alias regression skipped.' }
$projectPath = Join-Path $cli 'late.json'
[IO.File]::WriteAllText($projectPath, '{"format_version":1,"entries":[{"source":"a.pas","output":"late/a.spv"},{"source":"a.pas","output":"late2/b.spv","bindings":"late2/bad-name.pas"}]}', $utf8)
$late = Invoke-Tool $compiler @('build', $projectPath, '--force')
Assert-True ($late.Code -eq 2 -and -not (Test-Path (Join-Path $cli 'late\a.spv'))) 'Bindings unit name was validated after writing outputs'
$projectPath = Join-Path $cli 'duplicate.json'
[IO.File]::WriteAllText($projectPath, '{"format_version":1,"entries":[{"source":"a.pas","output":"d/first.spv","output":"d/second.spv"}]}', $utf8)
$duplicate = Invoke-Tool $compiler @('build', $projectPath, '--force')
Assert-True ($duplicate.Code -eq 2 -and $duplicate.Err -match 'Duplicate project property') 'Duplicate JSON keys were accepted'
$script:checks += 2

if (-not $SkipDelphiTests) {
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\FloatLiteralCheck.dpr')
    $literals = Invoke-Tool (Join-Path $root 'build\bin\FloatLiteralCheck.exe') @((Join-Path $root 'tests\fixtures\float_literals.txt'))
    Assert-True ($literals.Code -eq 0 -and $literals.Out -match 'PASS:') "Real literal rounding regression: $($literals.Err)"
    $script:checks++
    # Generated units named like RTL identifiers must still compile and validate.
    $unitDir = Join-Path $cases 'a2-unit-names'
    New-Item -ItemType Directory -Force $unitDir | Out-Null
    $layoutShader = Join-Path $unitDir 'layout.pas'
    [IO.File]::WriteAllText($layoutShader, 'type T = record V: Single3; W: Single; A: array[0..1] of Single3; end; var [Binding(0,0)] D: array of T; procedure Main; begin end;', $utf8)
    foreach ($unitName in @('SizeOf', 'Byte', 'Double', 'NativeUInt', 'EInvalidOpException')) {
        $bindings = Join-Path $unitDir "$unitName.pas"
        $generated = Invoke-Tool $compiler @($layoutShader, '-o', (Join-Path $unitDir "$unitName.spv"), '--bindings', $bindings)
        Assert-True ($generated.Code -eq 0) "Bindings unit $unitName was not generated: $($generated.Err)"
        $program = Join-Path $unitDir "Use$unitName.dpr"
        [IO.File]::WriteAllText($program, "program Use$unitName;`n{`$APPTYPE CONSOLE}`nuses $unitName in '$unitName.pas';`nbegin`n  PTS_ValidateLayouts;`n  Writeln('PASS');`nend.", $utf8)
        & (Join-Path $root 'scripts\build.ps1') -Project $program | Out-Null
        $run = Invoke-Tool (Join-Path $root "build\bin\Use$unitName.exe") @()
        Assert-True ($run.Code -eq 0 -and $run.Out -match 'PASS') "Generated unit named $unitName does not compile/validate"
        $script:checks++
    }
}
else { Write-Warning 'Real literal and RTL-named bindings checks were explicitly skipped (-SkipDelphiTests).' }
