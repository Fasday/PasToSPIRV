param(
    [switch]$SkipBuild,
    [Alias('SkipHostABI')][switch]$SkipDelphiTests,
    [string]$SpirvVal,
    [string]$SpirvDis
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}
$compiler = Join-Path $root 'build\bin\PasToSPIRV.exe'
$cases = Join-Path $root 'build\tests'
New-Item -ItemType Directory -Force -Path $cases | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:checks = 0

function Find-SpirvTool([string]$Name, [string]$ExplicitPath) {
    if ($ExplicitPath) { return (Resolve-Path $ExplicitPath).Path }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    if ($env:VULKAN_SDK) {
        $candidate = Join-Path $env:VULKAN_SDK "Bin\$Name.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    throw "$Name is required for tests. Install Vulkan SDK or pass an explicit tool path."
}

$SpirvVal = Find-SpirvTool 'spirv-val' $SpirvVal
$SpirvDis = Find-SpirvTool 'spirv-dis' $SpirvDis

function Invoke-Tool([string]$Path, [string[]]$ToolArgs, [string]$WorkingDirectory = '') {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Path
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    $info.Arguments = ($ToolArgs | ForEach-Object {
        # Windows native quoting: double backslashes before quotes/end-of-argument.
        $escaped = [regex]::Replace($_, '(\\*)"', '$1$1\"')
        '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
    }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw "Tool timed out: $Path"
        }
        return [pscustomobject]@{
            Code = $process.ExitCode
            Out = $stdout.GetAwaiter().GetResult()
            Err = $stderr.GetAwaiter().GetResult()
        }
    }
    finally { $process.Dispose() }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Test-Success([string]$Name, [string]$Source, [string]$Instruction = '') {
    $inputPath = Join-Path $cases "$Name.pas"
    $outputPath = Join-Path $cases "$Name.spv"
    [IO.File]::WriteAllText($inputPath, $Source, $utf8)
    $result = Invoke-Tool $compiler @('compile', $inputPath, '-o', $outputPath)
    Assert-True ($result.Code -eq 0) "$Name failed to compile: $($result.Err)"
    $validation = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.0', $outputPath)
    Assert-True ($validation.Code -eq 0) "$Name is invalid SPIR-V: $($validation.Out)$($validation.Err)"
    $bytes = [IO.File]::ReadAllBytes($outputPath)
    Assert-True (($bytes.Length % 4 -eq 0) -and ($bytes.Length -ge 20)) "$Name has an invalid module size"
    Assert-True ([BitConverter]::ToUInt32($bytes, 0) -eq 0x07230203) "$Name has an invalid SPIR-V magic"
    Assert-True ([BitConverter]::ToUInt32($bytes, 4) -eq 0x00010000) "$Name has an unexpected SPIR-V version"
    $json = Get-Content ([IO.Path]::ChangeExtension($outputPath, '.json')) -Raw | ConvertFrom-Json
    Assert-True ($json.entry_point -eq 'Main') "$Name has an invalid entry point"
    Assert-True ($json.target_env -eq 'vulkan1.0') "$Name has an invalid target environment"
    if ($Instruction) {
        $assembly = Invoke-Tool $SpirvDis @($outputPath)
        Assert-True ($assembly.Code -eq 0) "$Name failed to disassemble"
        Assert-True ($assembly.Out -match "\b$Instruction\b") "$Name does not contain $Instruction"
    }
    $script:checks++
}

function Test-Failure([string]$Name, [string]$Source, [string]$Message) {
    $inputPath = Join-Path $cases "$Name.pas"
    $outputPath = Join-Path $cases "$Name.spv"
    $reflectionPath = [IO.Path]::ChangeExtension($outputPath, '.json')
    [IO.File]::WriteAllText($inputPath, $Source, $utf8)
    [IO.File]::WriteAllText($outputPath, 'keep-existing-output', $utf8)
    [IO.File]::WriteAllText($reflectionPath, 'keep-existing-reflection', $utf8)
    $result = Invoke-Tool $compiler @($inputPath, '-o', $outputPath)
    Assert-True ($result.Code -eq 1) "$Name expected source error (1), got $($result.Code): $($result.Err)"
    Assert-True ($result.Err -match $Message) "$Name expected '$Message', got: $($result.Err)"
    Assert-True ($result.Err -match '\(\d+,\d+\): error:') "$Name has no source position"
    Assert-True ([IO.File]::ReadAllText($outputPath) -eq 'keep-existing-output') "$Name overwrote SPIR-V on failure"
    Assert-True ([IO.File]::ReadAllText($reflectionPath) -eq 'keep-existing-reflection') "$Name overwrote reflection on failure"
    $script:checks++
}

foreach ($name in @('empty', 'scale', 'integer_math', 'functions_for', 'vector_math', 'layout_records', 'atomic_histogram', 'shared_reduce', 'storage_image', 'sample_texture')) {
    Test-Success $name ([IO.File]::ReadAllText((Join-Path $root "examples\$name.pas")))
}
Test-Success 'integer_edges' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\integer_edges.pas'))) 'OpSRem'
Test-Success 'for_edges' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\for_edges.pas'))) 'OpPhi'
Test-Success 'function_edges' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\function_edges.pas'))) 'OpFunctionCall'
Test-Success 'vector_edges' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\vector_edges.pas'))) 'OpAll'
Test-Success 'intrinsic_edges' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\intrinsic_edges.pas'))) 'OpExtInstImport'
Test-Success 'aggregate_values' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\aggregate_values.pas'))) 'OpConstantNull'
Test-Success 'atomic_values' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\atomic_values.pas'))) 'OpAtomicCompareExchange'
Test-Success 'path with spaces' 'procedure Main; begin end;'
Test-Success 'utf8_bom' ([string][char]0xFEFF + 'procedure Main; begin end;')

$scale = Get-Content (Join-Path $cases 'scale.json') -Raw | ConvertFrom-Json
Assert-True (($scale.local_size -join ',') -eq '64,1,1') 'Incorrect local size reflection'
Assert-True ($scale.buffers.Count -eq 2) 'Incorrect buffer count'
Assert-True ($scale.buffers[0].binding -eq 0 -and $scale.buffers[1].binding -eq 1) 'Incorrect binding reflection'
Assert-True ($scale.buffers[0].access -eq 'read_only') 'Incorrect access reflection'
Assert-True ($scale.buffers[1].array_stride -eq 4) 'Incorrect array stride'
Assert-True ($scale.push_constants[0].size -eq 8) 'Incorrect push-constant size'
Assert-True ($scale.push_constants[0].members[1].offset -eq 4) 'Incorrect push-constant layout'
$script:checks++
$scaleAssembly = Invoke-Tool $SpirvDis @((Join-Path $cases 'scale.spv'))
Assert-True ($scaleAssembly.Code -eq 0 -and $scaleAssembly.Out -match '\bNoContraction\b') 'Float contraction was not disabled'
$script:checks++

$numericTypes = @(
    @{ Type = 'Integer'; A = '-7'; B = '3'; Ops = @('+:OpIAdd', '-:OpISub', '*:OpIMul', 'div:OpSDiv', 'mod:OpSRem', 'and:OpBitwiseAnd', 'or:OpBitwiseOr', 'xor:OpBitwiseXor', 'shl:OpShiftLeftLogical', 'shr:OpShiftRightLogical', '/:OpFDiv') },
    @{ Type = 'Cardinal'; A = '7'; B = '3'; Ops = @('+:OpIAdd', '-:OpISub', '*:OpIMul', 'div:OpUDiv', 'mod:OpUMod', 'and:OpBitwiseAnd', 'or:OpBitwiseOr', 'xor:OpBitwiseXor', 'shl:OpShiftLeftLogical', 'shr:OpShiftRightLogical', '/:OpFDiv') },
    @{ Type = 'Single'; A = '-7.5'; B = '3.0'; Ops = @('+:OpFAdd', '-:OpFSub', '*:OpFMul', '/:OpFDiv') }
)
$index = 0
foreach ($type in $numericTypes) {
    foreach ($spec in $type.Ops) {
        $op, $instruction = $spec.Split(':')
        $resultType = $type.Type
        if ($op -eq '/') { $resultType = 'Single' }
        $source = "procedure Main; var A: $($type.Type); B: $($type.Type); R: $resultType; begin A := $($type.A); B := $($type.B); R := A $op B; end;"
        Test-Success "numeric_$index" $source $instruction
        $index++
    }
    foreach ($op in @('=', '<>', '<', '<=', '>', '>=')) {
        $source = "procedure Main; var A: $($type.Type); B: $($type.Type); R: Boolean; begin A := $($type.A); B := $($type.B); R := A $op B; end;"
        Test-Success "comparison_$index" $source
        $index++
    }
}

foreach ($spec in @('and:OpLogicalAnd', 'or:OpLogicalOr', 'xor:OpLogicalNotEqual', '=:OpLogicalEqual', '<>:OpLogicalNotEqual')) {
    $op, $instruction = $spec.Split(':')
    Test-Success "boolean_$index" "procedure Main; var A: Boolean; B: Boolean; begin A := True; B := False; A := A $op B; end;" $instruction
    $index++
}

Test-Success 'casts' @'
procedure Main;
var I: Integer; U: Cardinal; F: Single; B: Boolean;
begin
  I := -1; U := Cardinal(I); I := Integer(U);
  F := Single(I); F := Single(U);
  I := Integer(F); U := Cardinal(F);
  F := Single(I) + U; F := 1e-3; B := Boolean(True);
end;
'@ 'OpBitcast'

Test-Success 'unary' 'procedure Main; var I: Integer; U: Cardinal; F: Single; B: Boolean; begin I := -2147483648; I := -I; I := not I; U := $FFFFFFFF; U := not U; F := -1.5; F := -F; B := not False; I := +I; end;' 'OpNot'
Test-Success 'unsigned_literal_promotion' 'procedure Main; var U: Cardinal; B: Boolean; begin U := 1; U := U + 1; U := $FFFFFFFF + 1; B := U < 10; end;'
Test-Success 'branch_initialization' 'procedure Main; var I: Integer; begin if True then I := 1 else I := 2; I := I + 1; end;' 'OpSelectionMerge'
Test-Success 'nested_flow' 'procedure Main; var I: Integer; begin I := 0; while I < 5 do begin if I = 2 then begin if True then I := I + 1 else I := I + 2; end else I := I + 1; end; end;' 'OpLoopMerge'
Test-Success 'case_and_comments' "{ first }`r`nPrOcEdUrE mAiN; (* second *)`r`nVaR Value: CaRdInAl;`r`nBeGiN // third`r`n VALUE := globalinvocationid.y + GlobalInvocationID.z;`r`neNd; // EOF"
Test-Success 'mixed_shift_count' 'procedure Main; var I: Integer; U: Cardinal; begin I := -1; U := 33; I := I shr U; U := U shl -1; end;' 'OpBitwiseAnd'
Test-Success 'nonzero_binding' 'var [Binding(2, 7)] Data: array of Cardinal; [LocalSize(4, 2, 1)] procedure Main; begin Data[GlobalInvocationID.X] := 1; end;'
$binding = Get-Content (Join-Path $cases 'nonzero_binding.json') -Raw | ConvertFrom-Json
Assert-True ($binding.buffers[0].set -eq 2 -and $binding.buffers[0].binding -eq 7) 'Nonzero descriptor coordinates were lost'
Assert-True (($binding.local_size -join ',') -eq '4,2,1') 'Explicit local size was lost'
$script:checks++

$featureSuccesses = @(
    @('function_scopes', 'function A(Value: Integer): Integer; var I: Integer; begin I := Value; Result := I; end; function B(Value: Integer): Integer; var I: Integer; begin I := A(Value); Result := I + 1; end; procedure Main; var I: Integer; begin I := B(2); end;', 'OpFunctionParameter'),
    @('function_return_conversion', 'function F(Value: Integer): Single; begin Result := Value; end; procedure Main; var V: Single; begin V := F(2); end;', 'OpConvertSToF'),
    @('function_call_conversion', 'function F(Value: Single): Single; begin Result := Value; end; procedure Main; var I: Integer; V: Single; begin I := 2; V := F(I); end;', 'OpConvertSToF'),
    @('function_literal_unsigned', 'function F(Value: Cardinal): Cardinal; begin Result := Value; end; procedure Main; var U: Cardinal; begin U := F(1); end;', 'OpFunctionCall'),
    @('function_boolean_parameter', 'function F(Value: Boolean): Boolean; begin Result := not Value; end; procedure Main; var B: Boolean; begin B := F(False); end;', 'OpReturnValue'),
    @('function_local_return', 'function F(Value: Integer): Integer; var Local: Integer; begin Local := Value + 1; Result := Local; end; procedure Main; var I: Integer; begin I := F(2); end;', 'OpFunctionCall'),
    @('function_return_branch', 'function F(Value: Integer): Integer; begin if Value < 0 then Result := -Value else Result := Value; end; procedure Main; var I: Integer; begin I := F(-2); end;', 'OpSelectionMerge'),
    @('function_chain', 'function A(Value: Integer): Integer; begin Result := Value + 1; end; function B(Value: Integer): Integer; begin Result := A(A(Value)); end; procedure Main; var I: Integer; begin I := B(A(1)); end;', 'OpFunctionCall'),
    @('function_case_insensitive', 'FuNcTiOn AddOne(VaLuE: InTeGeR): InTeGeR; BeGiN rEsUlT := vAlUe + 1; EnD; procedure Main; var I: Integer; begin I := ADDONE(1); end;', 'OpFunctionCall'),
    @('function_unused', 'function Unused(Value: Integer): Integer; begin Result := Value; end; procedure Main; begin end;', 'OpReturnValue'),
    @('for_to', 'procedure Main; var I: Integer; Sum: Integer; begin Sum := 0; for I := 1 to 4 do Sum := Sum + I; end;', 'OpPhi'),
    @('for_downto', 'procedure Main; var I: Integer; Sum: Integer; begin Sum := 0; for I := 4 downto 1 do Sum := Sum + I; end;', 'OpSGreaterThanEqual'),
    @('for_unsigned', 'procedure Main; var I: Cardinal; Sum: Cardinal; begin Sum := 0; for I := 0 to 2 do Sum := Sum + I; end;', 'OpULessThanEqual'),
    @('for_unsigned_down', 'procedure Main; var I: Cardinal; begin for I := 2 downto 0 do begin end; end;', 'OpUGreaterThanEqual'),
    @('for_after_if', 'procedure Main; var I: Integer; N: Integer; begin N := 0; if True then N := 3 else N := 4; for I := 1 to N do N := N + I; end;', 'OpPhi'),
    @('for_inside_while', 'procedure Main; var I: Integer; N: Integer; begin N := 0; while N < 2 do begin for I := 0 to 1 do N := N + 1; end; end;', 'OpLoopMerge'),
    @('while_inside_for', 'procedure Main; var I: Integer; N: Integer; begin for I := 0 to 1 do begin N := 0; while N < 2 do N := N + 1; end; end;', 'OpLoopMerge'),
    @('for_reinitialize', 'procedure Main; var I: Integer; begin for I := 1 to 0 do begin end; I := 10; I := I + 1; end;', 'OpPhi'),
    @('for_counter_by_value', 'function F(I: Integer): Integer; begin I := I + 1; Result := I; end; procedure Main; var I: Integer; Sum: Integer; begin Sum := 0; for I := 0 to 2 do Sum := Sum + F(I); end;', 'OpFunctionCall'),
    @('for_bounds_call', 'function F(Value: Integer): Integer; begin Result := Value; end; procedure Main; var I: Integer; begin for I := F(0) to F(2) do begin end; end;', 'OpFunctionCall')
)
foreach ($case in $featureSuccesses) { Test-Success $case[0] $case[1] $case[2] }

$failures = @(
    @('undeclared', 'procedure Main; begin Missing := 1; end;', 'Unknown identifier'),
    @('uninitialized', 'procedure Main; var I: Integer; begin I := I + 1; end;', 'uninitialized'),
    @('branch_uninitialized', 'procedure Main; var I: Integer; begin if True then I := 1; I := I + 1; end;', 'uninitialized'),
    @('else_uninitialized', 'procedure Main; var I: Integer; begin if True then I := 1 else I := I + 1; end;', 'uninitialized'),
    @('loop_uninitialized', 'procedure Main; var I: Integer; begin while False do I := 1; I := I + 1; end;', 'uninitialized'),
    @('readonly', 'var [Binding(0,0), ReadOnly] Data: array of Single; procedure Main; begin Data[0] := 1.0; end;', 'ReadOnly'),
    @('writeonly', 'var [Binding(0,0), WriteOnly] Data: array of Single; procedure Main; var F: Single; begin F := Data[0]; end;', 'WriteOnly'),
    @('push_write', 'var [PushConstant] P: record N: Cardinal; end; procedure Main; begin P.N := 1; end;', 'read-only'),
    @('builtin_write', 'procedure Main; begin GlobalInvocationID.X := 1; end;', 'read-only'),
    @('binding_duplicate', 'var [Binding(0,0)] A: array of Integer; [Binding(0,0)] B: array of Integer; procedure Main; begin end;', 'Duplicate descriptor'),
    @('binding_missing', 'var A: array of Integer; procedure Main; begin end;', 'require.*Binding'),
    @('access_duplicate', 'var [Binding(0,0), ReadOnly, WriteOnly] A: array of Integer; procedure Main; begin end;', 'conflicting'),
    @('attribute_unknown', '[Unknown] procedure Main; begin end;', 'Unknown attribute'),
    @('attribute_wrong_target', '[Binding(0,0)] procedure Main; begin end;', 'Only LocalSize'),
    @('localsize_zero', '[LocalSize(0,1,1)] procedure Main; begin end;', '1\.\.1024'),
    @('localsize_product', '[LocalSize(1024,2,1)] procedure Main; begin end;', '1024 invocations'),
    @('localsize_duplicate', '[LocalSize(1,1,1),LocalSize(1,1,1)] procedure Main; begin end;', 'Duplicate LocalSize'),
    @('boolean_buffer', 'var [Binding(0,0)] A: array of Boolean; procedure Main; begin end;', 'Boolean is not supported'),
    @('boolean_push', 'var [PushConstant] P: record B: Boolean; end; procedure Main; begin end;', 'Boolean is not supported'),
    @('mixed_signedness', 'procedure Main; var I: Integer; U: Cardinal; begin I := 1; U := 1; U := U + I; end;', 'Cannot convert'),
    @('narrowing', 'procedure Main; var I: Integer; begin I := 1.5; end;', 'Cannot convert'),
    @('boolean_cast', 'procedure Main; var B: Boolean; begin B := Boolean(1); end;', 'Cannot convert'),
    @('bad_condition', 'procedure Main; begin if 1 then begin end; end;', 'Boolean'),
    @('real_div', 'procedure Main; var F: Single; begin F := 1.0 div 2.0; end;', 'integer operands'),
    @('real_bitwise', 'procedure Main; var F: Single; begin F := 1.0 and 2.0; end;', 'integer operands'),
    @('unsigned_negation', 'procedure Main; var U: Cardinal; begin U := 1; U := -U; end;', 'Unary -'),
    @('integer_range', 'procedure Main; var U: Cardinal; begin U := 4294967296; end;', 'Cannot convert'),
    @('float_range', 'procedure Main; var F: Single; begin F := 1e100; end;', 'Single range'),
    @('exponent', 'procedure Main; var F: Single; begin F := 1e+; end;', 'exponent digits'),
    @('hex_digits', 'procedure Main; var U: Cardinal; begin U := $G; end;', 'hexadecimal digits'),
    @('numeric_suffix', 'procedure Main; var I: Integer; begin I := 1abc; end;', 'numeric literal'),
    @('comment_brace', '{ unterminated', 'Unterminated comment'),
    @('comment_paren', '(* unterminated', 'Unterminated comment'),
    @('directive', '{$Q+} procedure Main; begin end;', 'directives are not supported'),
    @('directive_paren', '(*$R+*) procedure Main; begin end;', 'directives are not supported'),
    @('duplicate_name', 'procedure Main; var Value: Integer; VALUE: Integer; begin end;', 'Duplicate identifier'),
    @('reserved_name', 'procedure Main; var GlobalInvocationID: Integer; begin end;', 'reserved'),
    @('duplicate_field', 'var [PushConstant] P: record N: Integer; n: Cardinal; end; procedure Main; begin end;', 'Duplicate.*field'),
    @('multiple_push', 'var [PushConstant] P: record N: Cardinal; end; [PushConstant] Q: record N: Cardinal; end; procedure Main; begin end;', 'Only one'),
    @('empty_push', 'var [PushConstant] P: record end; procedure Main; begin end;', 'must not be empty'),
    @('push_binding', 'var [PushConstant,Binding(0,0)] P: record N: Integer; end; procedure Main; begin end;', 'cannot have Binding'),
    @('unknown_field', 'var [PushConstant] P: record N: Integer; end; procedure Main; var I: Integer; begin I := P.Missing; end;', 'Unknown.*field'),
    @('float_index', 'var [Binding(0,0)] A: array of Single; procedure Main; begin A[1.0] := 2.0; end;', 'indices must have type'),
    @('missing_semicolon', 'procedure Main; var I: Integer; begin I := 1 I := 2; end;', 'Expected.*;'),
    @('extra_procedure', 'procedure Main; begin end; procedure Other; begin end;', 'end of file'),
    @('extended_type_requires_profile', 'procedure Main; var F: Double; begin end;', 'requires.*Vulkan12'),
    @('invalid_character', 'procedure Main; begin @ end;', 'Unsupported character')
)
foreach ($case in $failures) { Test-Failure $case[0] $case[1] $case[2] }
$featureFailures = @(
    @('function_recursion', 'function F(V: Integer): Integer; begin Result := F(V); end; procedure Main; begin end;', 'Recursion'),
    @('function_mutual_recursion', 'function A(V: Integer): Integer; begin Result := B(V); end; function B(V: Integer): Integer; begin Result := A(V); end; procedure Main; begin end;', 'declared before use'),
    @('function_forward_reference', 'function A: Integer; begin Result := B(); end; function B: Integer; begin Result := 1; end; procedure Main; begin end;', 'declared before use'),
    @('function_undefined', 'procedure Main; var I: Integer; begin I := Missing(1); end;', 'Unknown identifier'),
    @('function_duplicate', 'function F: Integer; begin Result := 1; end; function f: Integer; begin Result := 2; end; procedure Main; begin end;', 'Duplicate identifier'),
    @('function_resource_collision', 'var [Binding(0,0)] Data: array of Integer; function Data: Integer; begin Result := 1; end; procedure Main; begin end;', 'Duplicate identifier'),
    @('function_parameter_duplicate', 'function F(Value: Integer; VALUE: Integer): Integer; begin Result := Value; end; procedure Main; begin end;', 'Duplicate identifier'),
    @('function_parameter_local_collision', 'function F(Value: Integer): Integer; var Value: Integer; begin Result := 1; end; procedure Main; begin end;', 'Duplicate identifier'),
    @('function_parameter_global_shadow', 'var [Binding(0,0)] Data: array of Integer; function F(Data: Integer): Integer; begin Result := Data; end; procedure Main; begin end;', 'Duplicate identifier'),
    @('function_parameter_function_shadow', 'function F(F: Integer): Integer; begin Result := 1; end; procedure Main; begin end;', 'Duplicate identifier'),
    @('function_var_parameter_profile', 'function F(var Value: Integer): Integer; begin Result := Value; end; procedure Main; begin end;', 'require.*Vulkan12'),
    @('function_out_parameter_unassigned', 'function F(out Value: Integer): Integer; begin Result := 1; end; procedure Main; begin end;', 'uninitialized'),
    @('function_const_parameter_write', 'function F(const Value: Integer): Integer; begin Value := 1; Result := Value; end; procedure Main; begin end;', 'read-only'),
    @('function_missing_result', 'function F: Integer; begin end; procedure Main; begin end;', 'uninitialized Result'),
    @('function_partial_result', 'function F(V: Integer): Integer; begin if V > 0 then Result := 1; end; procedure Main; begin end;', 'uninitialized Result'),
    @('function_read_result', 'function F: Integer; begin Result := Result + 1; end; procedure Main; begin end;', 'uninitialized'),
    @('function_result_only_loop', 'function F: Integer; var I: Integer; begin for I := 1 to 2 do Result := I; end; procedure Main; begin end;', 'uninitialized Result'),
    @('function_return_type', 'function F: Boolean; begin Result := 1; end; procedure Main; begin end;', 'Cannot convert'),
    @('function_argument_type', 'function F(V: Integer): Integer; begin Result := V; end; procedure Main; var I: Integer; begin I := F(True); end;', 'Cannot convert'),
    @('function_argument_signedness', 'function F(V: Cardinal): Cardinal; begin Result := V; end; procedure Main; var I: Integer; U: Cardinal; begin I := 1; U := F(I); end;', 'Cannot convert'),
    @('function_too_few', 'function F(A,B: Integer): Integer; begin Result := A + B; end; procedure Main; var I: Integer; begin I := F(1); end;', 'expects 2 arguments'),
    @('function_too_many', 'function F(A: Integer): Integer; begin Result := A; end; procedure Main; var I: Integer; begin I := F(1,2); end;', 'Too many arguments'),
    @('function_missing_arguments', 'function F(V: Integer): Integer; begin Result := V; end; procedure Main; var I: Integer; begin I := F; end;', 'expects 1 arguments'),
    @('procedure_value_call', 'procedure F; begin end; procedure Main; var I: Integer; begin I := F(); end;', 'Cannot convert'),
    @('function_other_name_assign', 'function G: Integer; begin Result := 1; end; function F: Integer; begin G := 1; Result := 1; end; procedure Main; begin end;', 'cannot assign to a function'),
    @('function_main_call', 'procedure Main; var I: Integer; begin I := Main(); end;', 'Main cannot be called'),
    @('function_local_leak', 'function F: Integer; var Local: Integer; begin Local := 1; Result := Local; end; procedure Main; var I: Integer; begin I := Local; end;', 'Unknown identifier'),
    @('function_parameter_leak', 'function F(Value: Integer): Integer; begin Result := Value; end; procedure Main; var I: Integer; begin I := Value; end;', 'Unknown identifier'),
    @('function_result_outside', 'procedure Main; begin Result := 1; end;', 'Unknown identifier'),
    @('function_reserved_result', 'procedure Main; var Result: Integer; begin end;', 'reserved'),
    @('function_global_read_access', 'var [Binding(0,0),WriteOnly] Data: array of Integer; function F: Integer; begin Result := Data[0]; end; procedure Main; begin end;', 'Cannot read'),
    @('function_global_write_access', 'var [Binding(0,0),ReadOnly] Data: array of Integer; function F: Integer; begin Data[0] := 1; Result := 1; end; procedure Main; begin end;', 'Cannot write'),
    @('function_push_write', 'var [PushConstant] P: record N: Integer; end; function F: Integer; begin P.N := 1; Result := 1; end; procedure Main; begin end;', 'read-only'),
    @('function_builtin_write', 'function F: Cardinal; begin GlobalInvocationID.X := 1; Result := 1; end; procedure Main; begin end;', 'read-only'),
    @('function_attribute', '[LocalSize(1,1,1)] function F: Integer; begin Result := 1; end; procedure Main; begin end;', 'Attributes are not supported'),
    @('function_uninitialized_argument', 'function F(V: Integer): Integer; begin Result := V; end; procedure Main; var I: Integer; begin I := F(I); end;', 'uninitialized'),
    @('for_counter_write', 'procedure Main; var I: Integer; begin for I := 0 to 2 do I := I + 1; end;', 'active for-loop counter'),
    @('for_counter_reuse', 'procedure Main; var I: Integer; begin for I := 0 to 2 do for I := 0 to 1 do begin end; end;', 'active for-loop counter'),
    @('for_float_counter', 'procedure Main; var I: Single; begin for I := 0 to 2 do begin end; end;', 'local Integer or Cardinal'),
    @('for_bool_counter', 'procedure Main; var I: Boolean; begin for I := False to True do begin end; end;', 'local Integer or Cardinal'),
    @('for_buffer_counter', 'var [Binding(0,0)] Data: array of Integer; procedure Main; begin for Data[0] := 0 to 2 do begin end; end;', 'local Integer or Cardinal'),
    @('for_parameter_counter', 'function F(I: Integer): Integer; begin Result := 0; for I := 0 to 2 do Result := Result + I; end; procedure Main; begin end;', 'local Integer or Cardinal'),
    @('for_result_counter', 'function F: Integer; begin for Result := 0 to 2 do begin end; end; procedure Main; begin end;', 'local Integer or Cardinal'),
    @('for_bound_float', 'procedure Main; var I: Integer; begin for I := 0 to 2.5 do begin end; end;', 'Cannot convert'),
    @('for_bound_boolean', 'procedure Main; var I: Integer; begin for I := 0 to True do begin end; end;', 'Cannot convert'),
    @('for_bound_signedness', 'procedure Main; var I: Cardinal; J: Integer; begin J := 0; for I := J to 2 do begin end; end;', 'Cannot convert'),
    @('for_uninitialized_limit', 'procedure Main; var I: Integer; begin for I := 0 to I do begin end; end;', 'uninitialized'),
    @('for_counter_after', 'procedure Main; var I: Integer; N: Integer; begin I := 10; for I := 0 to 1 do begin end; N := I; end;', 'uninitialized'),
    @('for_body_initialization', 'procedure Main; var I: Integer; N: Integer; begin for I := 0 to 1 do N := 1; N := N + 1; end;', 'uninitialized'),
    @('for_counter_after_while', 'procedure Main; var I: Integer; N: Integer; begin I := 1; N := 0; while N < 1 do begin for I := 0 to 1 do begin end; N := N + 1; end; N := I; end;', 'uninitialized'),
    @('for_nested_invalidation', 'procedure Main; var I: Integer; J: Integer; N: Integer; begin J := 10; for I := 0 to 1 do for J := 0 to 1 do begin end; N := J; end;', 'uninitialized'),
    @('for_missing_direction', 'procedure Main; var I: Integer; begin for I := 0 do begin end; end;', 'to or downto')
)
foreach ($case in $featureFailures) { Test-Failure $case[0] $case[1] $case[2] }
. (Join-Path $root 'tests\vectors.ps1')
. (Join-Path $root 'tests\layout.ps1')
. (Join-Path $root 'tests\modules.ps1')
. (Join-Path $root 'tests\component.ps1')
. (Join-Path $root 'tests\release.ps1')
. (Join-Path $root 'tests\audit.ps1')
. (Join-Path $root 'tests\audit2.ps1')
. (Join-Path $root 'tests\sketch.ps1')
. (Join-Path $root 'tests\extended.ps1')
. (Join-Path $root 'tests\vulkan11.ps1')
. (Join-Path $root 'tests\audit11.ps1')
. (Join-Path $root 'tests\audit112.ps1')
. (Join-Path $root 'tests\syntax12.ps1')
. (Join-Path $root 'tests\syntax13.ps1')
. (Join-Path $root 'tests\softdouble.ps1')
. (Join-Path $root 'tests\entry_points.ps1')
. (Join-Path $root 'tests\graphics.ps1')
. (Join-Path $root 'tests\audit141.ps1')
Test-Failure 'nul' ("procedure Main; begin end;" + [char]0) 'NUL'
$fields = (1..33 | ForEach-Object { "N$($_): Cardinal;" }) -join ' '
Test-Failure 'large_push' "var [PushConstant] P: record $fields end; procedure Main; begin end;" '128 bytes'
$nested = ('(' * 150) + '1' + (')' * 150)
Test-Failure 'nesting_limit' "procedure Main; var I: Integer; begin I := $nested; end;" 'nesting limit'
$chain = (1..150 | ForEach-Object { '1' }) -join ' + '
Test-Failure 'expression_depth' "procedure Main; var I: Integer; begin I := $chain; end;" 'nesting limit'
Test-Failure 'position_lf' "procedure Main;`nbegin`n  Missing := 1;`nend;" '\(3,3\)'
Test-Failure 'position_crlf' "procedure Main;`r`nbegin`r`n  Missing := 1;`r`nend;" '\(3,3\)'
Test-Failure 'position_cr' "procedure Main;`rbegin`r  Missing := 1;`rend;" '\(3,3\)'

$version = Invoke-Tool $compiler @('--version')
$expectedVersion = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'source\PTS.Compiler.pas')), "CompilerVersion = '([^']+)'").Groups[1].Value
Assert-True ($version.Code -eq 0 -and $version.Out.Trim() -eq "PasToSPIRV $expectedVersion") 'Version command failed'
$help = Invoke-Tool $compiler @('--help')
Assert-True ($help.Code -eq 0 -and $help.Out -match 'Usage:') 'Help command failed'
foreach ($arguments in @(@('compile'), @('-o'), @('--unknown'), @('a.pas', 'b.pas'), @('a.pas', '-o', '--reflection'))) {
    $result = Invoke-Tool $compiler $arguments
    Assert-True ($result.Code -eq 2) "Expected usage error for: $arguments"
    $script:checks++
}
$inputPath = Join-Path $cases 'scale.pas'
$original = [IO.File]::ReadAllText($inputPath)
$collision = Invoke-Tool $compiler @($inputPath, '-o', $inputPath)
Assert-True ($collision.Code -eq 2) 'Input/output collision was not rejected'
Assert-True ([IO.File]::ReadAllText($inputPath) -eq $original) 'Input was overwritten'
$collision = Invoke-Tool $compiler @($inputPath, '-o', (Join-Path $cases 'collision.spv'), '--reflection', $inputPath)
Assert-True ($collision.Code -eq 2) 'Input/reflection collision was not rejected'
$missing = Invoke-Tool $compiler @((Join-Path $cases 'does-not-exist.pas'))
Assert-True ($missing.Code -eq 2) 'Missing input was not reported as an I/O error'
$script:checks += 5

$repeatPath = Join-Path $cases 'repeat.spv'
$repeat = Invoke-Tool $compiler @($inputPath, '-o', $repeatPath)
Assert-True ($repeat.Code -eq 0) 'Repeat compilation failed'
$firstHash = (Get-FileHash (Join-Path $cases 'scale.spv') -Algorithm SHA256).Hash
$secondHash = (Get-FileHash $repeatPath -Algorithm SHA256).Hash
Assert-True ($firstHash -eq $secondHash) 'Compilation is not deterministic'
$script:checks++

$customReflection = Join-Path $cases 'custom reflection\resources.json'
$custom = Invoke-Tool $compiler @($inputPath, '-o', $repeatPath, '--reflection', $customReflection)
Assert-True ($custom.Code -eq 0 -and (Test-Path $customReflection)) 'Explicit reflection path failed'
$defaultOutput = Invoke-Tool $compiler @((Join-Path $cases 'empty.pas'))
Assert-True ($defaultOutput.Code -eq 0) 'Default output paths failed'
$collision = Invoke-Tool $compiler @($inputPath, '-o', $repeatPath, '--reflection', $repeatPath)
Assert-True ($collision.Code -eq 2) 'SPIR-V/reflection collision was not rejected'
$script:checks += 3

Write-Host "PASS: $script:checks checks (including Vulkan 1.0/1.1/1.2 SPIR-V validation)."
