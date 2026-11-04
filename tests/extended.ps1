# Language 1.1, both the preserved Vulkan 1.0 profile and optional Vulkan 1.2.
function Test-Extended([string]$Name, [string]$Source, [string]$Instruction = '') {
    $inputPath = Join-Path $cases "$Name.pas"
    $outputPath = Join-Path $cases "$Name.spv"
    [IO.File]::WriteAllText($inputPath, $Source, $utf8)
    foreach ($mode in @('O0', 'O1')) {
        $argsList = @('compile', $inputPath, '-o', $outputPath)
        if ($mode -eq 'O1') { $argsList += '-O1' }
        $result = Invoke-Tool $compiler $argsList
        Assert-True ($result.Code -eq 0) "$Name $mode failed: $($result.Err)"
        $validation = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.2', $outputPath)
        Assert-True ($validation.Code -eq 0) "$Name $mode invalid: $($validation.Err)"
        $meta = Get-Content ([IO.Path]::ChangeExtension($outputPath, '.json')) -Raw | ConvertFrom-Json
        Assert-True ($meta.profile -eq 'compute-vulkan1.2') "$Name profile mismatch"
        if ($Instruction) {
            $asm = Invoke-Tool $SpirvDis @($outputPath)
            Assert-True ($asm.Out -match $Instruction) "$Name misses $Instruction"
        }
        $script:checks++
    }
}

foreach ($name in @('extended_numeric', 'extended_references', 'extended_alias')) {
    Test-Extended $name ([IO.File]::ReadAllText((Join-Path $root "tests\fixtures\$name.pas")))
}
Test-Success 'constant_tables' ([IO.File]::ReadAllText((Join-Path $root 'examples\constant_tables.pas'))) 'OpConstantComposite'
Test-Success 'procedure_resources' 'var [Binding(0,0)] D: array of Cardinal; procedure SetValue; begin D[GlobalInvocationID.X] := 7; end; procedure Main; begin SetValue(); end;' 'OpFunctionCall'
Test-Success 'const_value_parameter' 'function F(const V: Integer): Integer; begin Result := V; end; procedure Main; var I: Integer; begin I := F(3); F(4); end;' 'OpFunctionCall'
Test-Success 'return_branches' 'function F(B: Boolean): Integer; begin if B then Exit(1) else Exit(2); end; procedure Main; var I: Integer; begin I := F(True); end;' 'OpReturnValue'
Test-Success 'repeat_assignment' 'procedure Main; var X: Integer; begin repeat X := 1; until True; X := X + 1; end;' 'OpLoopMerge'
Test-Success 'case_assignment' 'procedure Main; var X: Integer; begin case GlobalInvocationID.X of 0: X := 1; 1,2: X := 2; else X := 3; end; X := X + 1; end;' 'OpSwitch'
Test-Extended 'wide_for' '[Vulkan12] procedure Main; var I: Int64; N: Int64; begin N := 0; for I := 9223372036854775806 to 9223372036854775807 do N := N + 1; end;' 'OpPhi'
Test-Extended 'small_push' 'var [PushConstant] P: record A: Byte; B: Word; C: Double; D: Int64; end; [Vulkan12] procedure Main; var D: Double; begin D := P.C; end;' 'StoragePushConstant8'
Test-Extended 'double_sqrt_clamp' '[Vulkan12] procedure Main; var D: Double; begin D := Sqrt(4.0d); D := Clamp(D, 1.0, 3.0d); end;' 'Sqrt'
Test-Extended 'small_arithmetic' '[Vulkan12] procedure Main; var B: Byte; W: Word; begin B := 255; B := B + 1; W := 65535; W := W + 1; end;' 'OpIAdd'
Test-Extended 'small_case' '[Vulkan12] procedure Main; var B: Byte; begin B := 1; case B of 0: B := 2; 1: B := 3; end; end;' 'OpSwitch'

$negative = @(
    @('wide_literal_overflow', '[Vulkan12] procedure Main; var X: UInt64; begin X := 18446744073709551616; end;', 'exceeds 64'),
    @('double_literal_overflow', '[Vulkan12] procedure Main; var X: Double; begin X := 1e400d; end;', 'Double range'),
    @('double_narrowing', '[Vulkan12] procedure Main; var X: Single; begin X := 1.0d; end;', 'Cannot convert'),
    @('small_literal_overflow', '[Vulkan12] procedure Main; var X: Byte; begin X := 256; end;', 'Cannot convert'),
    @('typed_const_initializer', 'const A: Integer = 1; B: Cardinal = A; procedure Main; begin end;', 'Cannot convert'),
    @('typed_cast_initializer', 'const A: UInt64 = Int64(1); [Vulkan12] procedure Main; begin end;', 'Cannot convert'),
    @('extended_broadcast', '[Vulkan12] procedure Main; var D: Double; V: Single3; begin D := 1.0d; V := Single3(1) + D; end;', 'scalar types'),
    @('out_read_before_write', 'procedure F(out X: Integer); begin X := X + 1; end; [Vulkan12] procedure Main; begin end;', 'uninitialized'),
    @('out_partial_path', 'procedure F(out X: Integer; B: Boolean); begin if B then X := 1; end; [Vulkan12] procedure Main; begin end;', 'uninitialized'),
    @('out_early_exit', 'procedure F(out X: Integer; B: Boolean); begin if B then Exit; X := 1; end; [Vulkan12] procedure Main; begin end;', 'uninitialized'),
    @('var_uninitialized', 'procedure F(var X: Integer); begin X := 1; end; [Vulkan12] procedure Main; var X: Integer; begin F(X); end;', 'uninitialized'),
    @('ref_literal', 'procedure F(var X: Integer); begin X := 1; end; [Vulkan12] procedure Main; begin F(1); end;', 'Expected'),
    @('ref_resource', 'var [Binding(0,0)] D: array of Integer; procedure F(var X: Integer); begin X := 1; end; [Vulkan12] procedure Main; begin F(D[0]); end;', 'function-local'),
    @('ref_wrong_type', 'procedure F(var X: Integer); begin X := 1; end; [Vulkan12] procedure Main; var X: Cardinal; begin X := 0; F(X); end;', 'match exactly'),
    @('break_outside', 'procedure Main; begin Break; end;', 'enclosing loop'),
    @('continue_outside', 'procedure Main; begin Continue; end;', 'enclosing loop'),
    @('case_no_default_assignment', 'procedure Main; var X: Integer; begin case GlobalInvocationID.X of 0: X := 1; end; X := X + 1; end;', 'uninitialized'),
    @('case_duplicate', 'procedure Main; begin case 1 of 1: begin end; 1: begin end; end; end;', 'Duplicate case'),
    @('return_missing', 'function F(B: Boolean): Integer; begin if B then Exit; Result := 1; end; procedure Main; begin end;', 'uninitialized Result'),
    @('procedure_value_return', 'procedure F; begin Exit(1); end; procedure Main; begin end;', 'cannot return'),
    @('continue_condition_read', 'procedure Main; var X: Integer; begin repeat if GlobalInvocationID.X = 0 then Continue; X := 1; until X = 1; end;', 'uninitialized'),
    @('break_assignment', 'procedure Main; var X: Integer; begin repeat if GlobalInvocationID.X = 0 then Break; X := 1; until True; X := X + 1; end;', 'uninitialized'),
    @('exit_barrier', 'procedure Main; begin if GlobalInvocationID.X = 0 then Exit; Barrier; end;', 'cannot Exit'),
    @('table_write', 'const A: array[0..1] of Integer = (1,2); procedure Main; begin A[0] := 3; end;', 'read-only'),
    @('table_short', 'const A: array[0..1] of Integer = (1); procedure Main; begin end;', 'between constant array'),
    @('table_long', 'const A: array[0..1] of Integer = (1,2,3); procedure Main; begin end;', 'exact number'),
    @('table_dynamic_initializer', 'const A: array[0..1] of Cardinal = (1,GlobalInvocationID.X); procedure Main; begin end;', 'GPU built-ins'),
    @('bitcast_type', 'procedure Main; var X: Single; begin X := BitsToSingle(1.0); end;', 'requires Cardinal'),
    @('helper_barrier_procedure', 'procedure F; begin Barrier; end; procedure Main; begin F(); end;', 'only available in Main'),
    @('atomic64', 'var [Binding(0,0)] D: array of UInt64; [Vulkan12] procedure Main; begin AtomicAdd(D[0],1); end;', 'scalar Integer or Cardinal')
)
foreach ($n in $negative) { Test-Failure $n[0] $n[1] $n[2] }

if (-not $SkipDelphiTests) {
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\ExtendedNumericCheck.dpr')
    $layoutOut = Join-Path $cases 'extended_layout.spv'
    $bindingsOut = Join-Path $cases 'ExtendedLayoutBindings.pas'
    $layout = Invoke-Tool $compiler @('compile', (Join-Path $root 'tests\fixtures\extended_layout.pas'),
        '-o', $layoutOut, '--bindings', $bindingsOut)
    Assert-True ($layout.Code -eq 0) "Extended layout failed: $($layout.Err)"
    $val = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.2', $layoutOut)
    Assert-True ($val.Code -eq 0) "Extended layout SPIR-V invalid: $($val.Err)"
    $meta = Get-Content ([IO.Path]::ChangeExtension($layoutOut, '.json')) -Raw | ConvertFrom-Json
    Assert-True (($meta.types[0].members.offset -join ',') -eq '0,2,8,16,24') 'Extended std430 offsets mismatch'
    Assert-True (($meta.buffers.array_stride -join ',') -eq '32,1,2,8') 'Extended std430 array strides mismatch'
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\ExtendedBindingsCheck.dpr')
    $run = Invoke-Tool (Join-Path $root 'build\bin\ExtendedBindingsCheck.exe') @()
    Assert-True ($run.Code -eq 0 -and $run.Out -match 'PASS:') "Extended bindings mismatch: $($run.Err)"
    $script:checks++
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $generated = Invoke-Tool $python.Source @((Join-Path $root 'tests\generate_double_literals.py'))
        Assert-True ($generated.Code -eq 0) "Double oracle generation failed: $($generated.Err)"
        & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\DoubleLiteralCheck.dpr')
        $run = Invoke-Tool (Join-Path $root 'build\bin\DoubleLiteralCheck.exe') @((Join-Path $cases 'double_literals.txt'))
        Assert-True ($run.Code -eq 0 -and $run.Out -match 'PASS:') "Double literal mismatch: $($run.Err)"
        $script:checks++
    }
    else { Write-Warning 'Binary64 Fraction oracle skipped: Python is not available.' }
}
