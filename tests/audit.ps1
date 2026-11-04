# Audit regressions. Isolated source projects preserve all artifacts on failure.
$auditFixture = Join-Path $root 'tests\fixtures\audit'
foreach ($name in @('qualified_local','qualified_builtin','qualified_boolean','qualified_type','qualified_resource')) {
    [void](Test-SourceProject "audit_$name" @{
        'main.pas' = [IO.File]::ReadAllText((Join-Path $auditFixture "$name.pas"))
        'M.pasm' = [IO.File]::ReadAllText((Join-Path $auditFixture 'M.pasm'))
    } 'module exports|Unknown exported')
}
[void](Test-SourceProject 'audit_qualified_anonymous_array' @{
    'main.pas'='uses M; type TData = M.array[0..1] of Integer; procedure Main; begin end;'
    'M.pasm'='module M;'
} 'Unknown exported type')
[void](Test-SourceProject 'audit_qualified_builtin_constant' @{
    'main.pas'='uses M; const Count = M.LocalInvocationIndex; procedure Main; begin end;'
    'M.pasm'='module M;'
} 'Unknown exported')
[void](Test-SourceProject 'audit_qualified_missing_lvalue' @{
    'main.pas'='uses M; procedure Main; var Value: Integer; begin Value := 7; M.Value := 8; end;'
    'M.pasm'='module M;'
} 'Unknown exported')
[void](Test-SourceProject 'audit_valid_qualified_boolean' @{
    'main.pas'='uses M; procedure Main; var Value: Boolean; begin Value := M.Enabled; end;'
    'M.pasm'='module M; const Enabled = True;'
})
[void](Test-SourceProject 'audit_record_shadows_namespace' @{
    'main.pas'='uses M; type TData = record Value: Integer; end; procedure Main; var M: TData; begin M := Default(TData); M.Value := 8; end;'
    'M.pasm'='module M;'
})
Test-Success 'audit_hidden_shared' ([IO.File]::ReadAllText((Join-Path $auditFixture 'hidden_shared.pas'))) 'OpAccessChain'
Test-Success 'audit_hidden_shared_read' 'var [Shared] Scratch: array[0..3] of Cardinal; function F: Cardinal; begin Result := Scratch[0]; end; procedure Main; begin end;' 'OpAccessChain'
Test-Success 'audit_explicit_shared_value' 'type TData = array[0..3] of Cardinal; var [Shared] Scratch: TData; function F(Value: TData): Cardinal; begin Result := Value[0]; end; [LocalSize(4,1,1)] procedure Main; var Value: Cardinal; begin Scratch[LocalInvocationIndex] := 0; Barrier; Value := F(Scratch); end;' 'OpFunctionCall'

if (-not $SkipDelphiTests) {
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\AuditNumericCheck.dpr')
    $numeric = Invoke-Tool (Join-Path $root 'build\bin\AuditNumericCheck.exe') @()
    Assert-True ($numeric.Code -eq 0 -and $numeric.Out -match 'rounding-independent=True' -and
        $numeric.Out -match 'denormal-independent=True' -and $numeric.Out -match 'caller-state-restored=True') "FP isolation regression: $($numeric.Out)$($numeric.Err)"
    $script:checks++
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\AuditShiftCheck.dpr')
    $shifts = Invoke-Tool (Join-Path $root 'build\bin\AuditShiftCheck.exe') @()
    Assert-True ($shifts.Code -eq 0 -and $shifts.Out -match 'PASS:') "Shift evaluator regression: $($shifts.Out)$($shifts.Err)"
    $script:checks++
}
else { Write-Warning 'Delphi floating-point environment audit was explicitly skipped (-SkipDelphiTests).' }
& (Join-Path $root 'tests\AuditFilesCheck.ps1')
$script:checks += 5
