# Audit 1.1: complete scalar-cast validation matrix and concrete regressions.
$auditTypes = @('Byte', 'Word', 'Integer', 'Cardinal', 'Int64', 'UInt64', 'Single', 'Double')
foreach ($from in $auditTypes) {
    foreach ($to in $auditTypes) {
        Test-Extended "a11_cast_${from}_${to}" "[Vulkan12] procedure Main; var A: $from; B: $to; begin A := $from(3); B := $to(A); end;"
    }
    foreach ($op in @('Min(A,A)', 'Max(A,A)', 'Abs(A)', 'Clamp(A,A,A)', 'Sqrt(A)')) {
        $to = $from
        if ($op -eq 'Sqrt(A)' -and $from -ne 'Double') { $to = 'Single' }
        $name = ($op -replace '[^A-Za-z]', '')
        Test-Extended "a11_intrinsic_${from}_$name" "[Vulkan12] procedure Main; var A: $from; B: $to; begin A := $from(3); B := $op; end;"
    }
}
Test-Extended 'a11_literals_lr' '[Vulkan12] procedure Main; var A: Int64; B: UInt64; begin A := $FFFFFFFF + $100000000; B := $80000000 + $FFFFFFFFFFFFFFFF; end;'
Test-Extended 'a11_literals_rl' '[Vulkan12] procedure Main; var A: Int64; B: UInt64; begin A := $100000000 + $FFFFFFFF; B := $FFFFFFFFFFFFFFFF + $80000000; end;'
Test-Extended 'a11_literals_equal_width' '[Vulkan12] procedure Main; var A: UInt64; begin A := $100000000 + $FFFFFFFFFFFFFFFF; A := $FFFFFFFFFFFFFFFF + $100000000; end;'
Test-Extended 'a11_var_late_init' 'procedure F(var X: Integer; V: Integer); begin X := X + V; end; function Init(out X: Integer): Integer; begin X := 4; Result := 3; end; [Vulkan12] procedure Main; var X: Integer; begin F(X, Init(X)); end;'
Test-Extended 'a11_float_index' 'type T = array[0..3] of Integer; procedure F(var X: Integer); begin X := 1; end; [Vulkan12] procedure Main; var A: T; begin A := Default(T); F(A[Integer(3.0d/2.0d)]); end;' 'OpFDiv'

$auditFailures = @(
    @('a11_cast_binary_assignment', 'procedure Main; var U: Cardinal; begin U := Integer(1+2); end;', 'Cannot convert'),
    @('a11_cast_unary_assignment', 'procedure Main; var U: Cardinal; begin U := Integer(-(-1)); end;', 'Cannot convert'),
    @('a11_cast_binary_initializer', 'const A: UInt64 = Integer(1+2); [Vulkan12] procedure Main; begin end;', 'Cannot convert'),
    @('a11_cast_binary_widen', '[Vulkan12] procedure Main; var U: Int64; begin U := Integer(1+2) + $100000000; end;', 'Cannot convert'),
    @('a11_unsigned_neg_cast32', 'procedure Main; var I: Integer; begin I := -Cardinal($80000000); end;', 'Unary -'),
    @('a11_unsigned_neg_const32', 'const A: Cardinal = $80000000; procedure Main; var I: Integer; begin I := -A; end;', 'Unary -'),
    @('a11_unsigned_neg_cast64', '[Vulkan12] procedure Main; var I: Int64; begin I := -UInt64($8000000000000000); end;', 'Unary -'),
    @('a11_unsigned_neg_const64', 'const A: UInt64 = $8000000000000000; [Vulkan12] procedure Main; var I: Int64; begin I := -A; end;', 'Unary -'),
    @('a11_out_cannot_init_earlier_value', 'procedure F(V: Integer; out X: Integer); begin X := V; end; [Vulkan12] procedure Main; var X: Integer; begin F(X,X); end;', 'uninitialized'),
    @('a11_var_cannot_use_same_call_out', 'procedure F(var A: Integer; out B: Integer); begin B := 4; A := A + 1; end; [Vulkan12] procedure Main; var X: Integer; begin F(X,X); end;', 'uninitialized'),
    @('a11_continue_later_iteration', 'procedure Main; var I: Integer; J: Integer; begin J := 0; repeat I := J; for J := 0 to 0 do begin end; until GlobalInvocationID.X = 0; end;', 'uninitialized')
)
foreach ($n in $auditFailures) { Test-Failure $n[0] $n[1] $n[2] }

$labels32 = ((0..16383) -join ',')
Test-Failure 'a11_case_word_overflow32' "procedure Main; begin case 0 of ${labels32}: begin end; end; end;" 'switch budget'
$labels64 = $labels32
Test-Failure 'a11_case_word_overflow64' "[Vulkan12] procedure Main; var I: UInt64; begin I := 0; case I of ${labels64}: begin end; end; end;" 'switch budget'

# A maximum-sized legal OpSwitch must still validate, not just reject all large cases.
$labels32 = ((0..16382) -join ',')
Test-Success 'a11_case_word_boundary32' "procedure Main; begin case 0 of ${labels32}: begin end; end; end;" 'OpSwitch'

$names = ((0..255 | ForEach-Object { "P$_" }) -join ',')
Test-Failure 'a11_function_parameters' "function F($names`: Integer): Integer; begin Result := 1; end; procedure Main; begin end;" '255 parameters'
$names = ((0..254 | ForEach-Object { "P$_" }) -join ',')
Test-Success 'a11_function_parameters_boundary' "function F($names`: Integer): Integer; begin Result := 1; end; procedure Main; begin end;" 'OpFunctionParameter'

# 128 references plus their dynamic indices expand to 256 SPIR-V parameters.
$names = ((0..127 | ForEach-Object { "P$_" }) -join ',')
$actuals = ((0..127 | ForEach-Object { 'A[GlobalInvocationID.X and 1]' }) -join ',')
Test-Failure 'a11_specialized_parameters' "type T = array[0..1] of Integer; procedure F(var $names`: Integer); begin end; [Vulkan12] procedure Main; var A: T; begin A := Default(T); F($actuals); end;" '255-parameter budget'

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    $flow = Invoke-Tool $python.Source @((Join-Path $root 'tests\audit_flow.py'), '--count', '300', '--spirv-val', $SpirvVal)
    Assert-True ($flow.Code -eq 0 -and $flow.Out -match 'PASS:') "Flow state audit failed: $($flow.Out)$($flow.Err)"
    $script:checks++
}
else { Write-Warning 'Explicit-state flow audit skipped: Python is not available.' }
