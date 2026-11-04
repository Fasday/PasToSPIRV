# Loaded by scripts/test.ps1; uses its CLI/validator helpers and check counter.

$vectorNumber = 0
foreach ($width in @(2, 3, 4)) {
    foreach ($base in @('Integer', 'Cardinal', 'Single')) {
        $type = "$base$width"
        $operations = @('+:OpIAdd', '-:OpISub', '*:OpIMul', '/:OpFDiv')
        if ($base -eq 'Single') {
            $operations = @('+:OpFAdd', '-:OpFSub', '*:OpFMul', '/:OpFDiv')
        }
        else {
            $division = 'OpSDiv'; $modulo = 'OpSRem'
            if ($base -eq 'Cardinal') { $division = 'OpUDiv'; $modulo = 'OpUMod' }
            $operations += @("div:$division", "mod:$modulo", 'and:OpBitwiseAnd', 'or:OpBitwiseOr',
                              'xor:OpBitwiseXor', 'shl:OpShiftLeftLogical', 'shr:OpShiftRightLogical')
        }
        foreach ($operation in $operations) {
            $op, $instruction = $operation.Split(':')
            $resultType = $type
            if ($op -eq '/') { $resultType = "Single$width" }
            Test-Success "vector_operation_$vectorNumber" "procedure Main; var A: $type; B: $type; R: $resultType; begin A := $type(3); B := $type(2); R := A $op B; end;" $instruction
            $vectorNumber++
        }
        foreach ($comparison in @('=:OpAll', '<>:OpAny')) {
            $op, $instruction = $comparison.Split(':')
            Test-Success "vector_comparison_$vectorNumber" "procedure Main; var A: $type; B: $type; R: Boolean; begin A := $type(3); B := $type(2); R := A $op B; end;" $instruction
            $vectorNumber++
        }
        $last = @('X', 'Y', 'Z', 'W')[$width - 1]
        $values = (1..$width) -join ','
        Test-Success "vector_components_$vectorNumber" "function Change(Value: $type): $type; begin Value.X := 9; Result := Value; Result.$last := 8; end; procedure Main; var V: $type; S: $base; begin V := $type($values); V := Change(V); S := (V + $type(1)).$last; V.$last := S; end;" 'OpAccessChain'
        $vectorNumber++
        Test-Success "vector_broadcast_$vectorNumber" "procedure Main; var V: $type; R: $type; begin V := $type(2); R := 2 * V + V * 2; end;" 'OpCompositeConstruct'
        $vectorNumber++
        Test-Success "vector_clamp_bounds_$vectorNumber" "procedure Main; var V: $type; begin V := Clamp($type(3), 1, 2); end;" 'OpExtInst'
        $vectorNumber++
        # Integer negation is 0 - X (wraparound-safe), not OpSNegate.
        $unary = '-'; $unaryInstruction = 'OpISub'
        if ($base -eq 'Single') { $unaryInstruction = 'OpFNegate' }
        if ($base -eq 'Cardinal') { $unary = 'not '; $unaryInstruction = 'OpNot' }
        Test-Success "vector_unary_$vectorNumber" "procedure Main; var V: $type; begin V := $type(3); V := $unary V; V := +V; end;" $unaryInstruction
        $vectorNumber++
    }

    foreach ($sourceBase in @('Integer', 'Cardinal', 'Single')) {
        foreach ($targetBase in @('Integer', 'Cardinal', 'Single')) {
            $sourceType = "$sourceBase$width"
            $targetType = "$targetBase$width"
            $instruction = ''
            if ($sourceBase -ne $targetBase) {
                if ($targetBase -eq 'Single') {
                    $instruction = 'OpConvertSToF'
                    if ($sourceBase -eq 'Cardinal') { $instruction = 'OpConvertUToF' }
                }
                elseif ($sourceBase -eq 'Single') {
                    $instruction = 'OpConvertFToS'
                    if ($targetBase -eq 'Cardinal') { $instruction = 'OpConvertFToU' }
                }
                else { $instruction = 'OpBitcast' }
            }
            Test-Success "vector_cast_$vectorNumber" "procedure Main; var A: $sourceType; R: $targetType; begin A := $sourceType(3); R := $targetType(A); end;" $instruction
            $vectorNumber++
        }
    }

    foreach ($leftBase in @('Integer', 'Cardinal', 'Single')) {
        foreach ($rightBase in @('Integer', 'Cardinal', 'Single')) {
            Test-Success "vector_dot_$vectorNumber" "procedure Main; var R: Single; begin R := Dot($leftBase$width(2), $rightBase$width(3)); end;" 'OpDot'
            $vectorNumber++
        }
    }
}

foreach ($width in @(1, 2, 3, 4)) {
    foreach ($base in @('Integer', 'Cardinal', 'Single')) {
        $type = $base; $floatType = 'Single'
        if ($width -gt 1) { $type = "$base$width"; $floatType = "Single$width" }
        $minOp = 'SMin'; $maxOp = 'SMax'; $clampOp = 'SClamp'; $absOp = 'OpSelect'
        if ($base -eq 'Cardinal') { $minOp = 'UMin'; $maxOp = 'UMax'; $clampOp = 'UClamp'; $absOp = '' }
        if ($base -eq 'Single') { $minOp = 'NMin'; $maxOp = 'NMax'; $clampOp = 'NClamp'; $absOp = 'FAbs' }
        foreach ($item in @(@('Min', $minOp), @('Max', $maxOp))) {
            Test-Success "intrinsic_binary_$vectorNumber" "procedure Main; var A: $type; B: $type; R: $type; begin A := $type(3); B := $type(2); R := $($item[0])(A, B); end;" $item[1]
            $vectorNumber++
        }
        Test-Success "intrinsic_clamp_$vectorNumber" "procedure Main; var R: $type; begin R := Clamp($type(3), $type(1), $type(2)); end;" $clampOp
        $vectorNumber++
        Test-Success "intrinsic_abs_$vectorNumber" "procedure Main; var R: $type; begin R := Abs($type(3)); end;" $absOp
        $vectorNumber++
        Test-Success "intrinsic_sqrt_$vectorNumber" "procedure Main; var R: $floatType; begin R := Sqrt($type(4)); end;" 'Sqrt'
        $vectorNumber++
    }
}

Test-Success 'vector_implicit_float' 'function F(V: Single3): Single3; begin Result := V; end; procedure Main; var I: Integer3; V: Single3; begin I := Integer3(1,2,3); V := F(I); V := V + I; end;' 'OpConvertSToF'
Test-Success 'vector_builtin_value' 'function F(V: Cardinal3): Cardinal3; begin Result := V + 1; end; procedure Main; var V: Cardinal3; I: Cardinal; begin V := F(GlobalInvocationID); I := V.Z; end;' 'OpFunctionCall'
Test-Success 'vector_scalar_sqrt_broadcast' 'procedure Main; var V: Single3; begin V := Single3(1,2,3); V := V / Sqrt(Dot(V,V)); end;' 'OpDot'
Test-Success 'vector_return_components' 'function F: Single4; begin Result := Single4(0); Result.W := 4; end; procedure Main; var S: Single; begin S := F().W; end;' 'OpAccessChain'
Test-Success 'vector_case_components' 'procedure Main; var V: sInGlE3; S: Single; begin V := SINGLE3(1,2,3); V.y := 4; S := (V * 2).z; end;' 'OpCompositeExtract'
Test-Success 'clamp_common_float' 'procedure Main; var V: Single3; begin V := Clamp(Integer3(0), Cardinal3(0), Single3(2)); end;' 'NClamp'
Test-Success 'clamp_shape_from_upper' 'procedure Main; var V: Single3; begin V := Clamp(0, 1, Single3(2)); end;' 'NClamp'
Test-Success 'clamp_common_float_reverse' 'procedure Main; var V: Single3; begin V := Clamp(Single3(0), Integer3(-1), Cardinal3(1)); end;' 'NClamp'
Test-Success 'vector_return_branches' 'function Choose(B: Boolean): Single3; begin if B then Result := Single3(1) else Result := Single3(2); end; procedure Main; var V: Single3; begin V := Choose(True); end;' 'OpReturnValue'
Test-Success 'vector_loop_value' 'procedure Main; var V: Single3; I: Integer; begin V := Single3(0); for I := 1 to 3 do V := V + I; end;' 'OpFAdd'

$vectorFailures = @(
    @('vector_width_assignment', 'procedure Main; var V: Single3; begin V := Single2(1); end;', 'Cannot convert'),
    @('vector_scalar_assignment', 'procedure Main; var V: Single3; begin V := 1; end;', 'Cannot convert'),
    @('vector_scalar_parameter', 'function F(V: Single3): Single3; begin Result := V; end; procedure Main; var V: Single3; begin V := F(1); end;', 'Cannot convert'),
    @('vector_scalar_return', 'function F: Single3; begin Result := 1; end; procedure Main; begin end;', 'Cannot convert'),
    @('vector_cast_width', 'procedure Main; var V: Single3; begin V := Single3(Single2(1)); end;', 'Cannot convert'),
    @('vector_cast_scalar', 'procedure Main; var S: Single; begin S := Single(Single3(1)); end;', 'Cannot convert'),
    @('vector_constructor_zero', 'procedure Main; var V: Single3; begin V := Single3(); end;', 'constructor expects'),
    @('vector_constructor_short', 'procedure Main; var V: Single3; begin V := Single3(1,2); end;', 'constructor expects'),
    @('vector_constructor_long', 'procedure Main; var V: Single2; begin V := Single2(1,2,3); end;', 'constructor expects'),
    @('vector_constructor_five', 'procedure Main; var V: Single4; begin V := Single4(1,2,3,4,5); end;', 'at most four'),
    @('vector_constructor_bool', 'procedure Main; var V: Single3; begin V := Single3(True); end;', 'Cannot convert'),
    @('vector_constructor_flatten', 'procedure Main; var V: Single4; begin V := Single4(Single3(1),2); end;', 'constructor expects'),
    @('vector_ordered', 'procedure Main; var B: Boolean; begin B := Single3(1) < Single3(2); end;', 'Ordered comparisons'),
    @('vector_compare_width', 'procedure Main; var B: Boolean; begin B := Single3(1) = Single2(1); end;', 'matching vector widths'),
    @('vector_compare_scalar', 'procedure Main; var B: Boolean; begin B := Single3(1) = 1; end;', 'matching vector widths'),
    @('vector_binary_width', 'procedure Main; var V: Single3; begin V := Single3(1) + Single2(1); end;', 'matching vector widths'),
    @('vector_signedness', 'procedure Main; var V: Cardinal3; begin V := Cardinal3(1) + Integer3(1); end;', 'Cannot convert'),
    @('vector_broadcast_signedness', 'procedure Main; var I: Integer; V: Cardinal3; begin I := 1; V := Cardinal3(1) + I; end;', 'Cannot convert'),
    @('vector_if', 'procedure Main; begin if Single3(1) then begin end; end;', 'Boolean'),
    @('vector_while', 'procedure Main; begin while Single3(1) do begin end; end;', 'Boolean'),
    @('vector_for_counter', 'procedure Main; var V: Integer3; begin for V := 0 to 1 do begin end; end;', 'local Integer or Cardinal'),
    @('vector_for_component', 'procedure Main; var V: Integer3; begin V := Integer3(0); for V.X := 0 to 1 do begin end; end;', 'local Integer or Cardinal'),
    @('vector_for_bound', 'procedure Main; var I: Integer; begin for I := 0 to Integer3(1) do begin end; end;', 'Cannot convert'),
    @('vector_buffer_index', 'var [Binding(0,0)] Data: array of Single; procedure Main; begin Data[Cardinal2(0)] := 1; end;', 'indices must have type'),
    @('vector_read_uninitialized', 'procedure Main; var V: Single3; S: Single; begin S := V.X; end;', 'uninitialized'),
    @('vector_partial_initialization', 'procedure Main; var V: Single3; begin V.X := 1; end;', 'initialized as a whole'),
    @('vector_result_partial', 'function F: Single3; begin Result.X := 1; end; procedure Main; begin end;', 'initialized as a whole'),
    @('vector_result_branch', 'function F(B: Boolean): Single3; begin if B then Result := Single3(1); end; procedure Main; begin end;', 'uninitialized Result'),
    @('vector_component_range', 'procedure Main; var V: Single2; S: Single; begin V := Single2(1); S := V.Z; end;', 'not available'),
    @('vector_component_write_range', 'procedure Main; var V: Single3; begin V := Single3(1); V.W := 2; end;', 'not available'),
    @('vector_swizzle_width', 'procedure Main; var V: Single3; S: Single; begin V := Single3(1); S := V.XY; end;', 'Cannot convert Single2 to Single'),
    @('vector_scalar_component', 'procedure Main; var I: Integer; begin I := 1; I.X := 2; end;', 'requires a vector'),
    @('vector_component_chain', 'procedure Main; var S: Single; begin S := Single3(1).X.X; end;', 'requires a vector'),
    @('vector_component_type', 'procedure Main; var V: Integer3; begin V := Integer3(1); V.X := True; end;', 'Cannot convert'),
    @('vector_shift_width', 'procedure Main; var I: Integer; begin I := 1 shl Integer3(1); end;', 'matching vector widths'),
    @('vector_shift_float', 'procedure Main; var V: Single3; begin V := Single3(1) shl 1; end;', 'must be integers'),
    @('vector_builtin_write', 'procedure Main; begin GlobalInvocationID := Cardinal3(0); end;', 'read-only'),
    @('vector_builtin_width', 'procedure Main; var I: Cardinal; begin I := GlobalInvocationID.W; end;', 'not available'),
    @('vector_type_reserved', 'procedure Main; var Single3: Integer; begin end;', 'reserved'),
    @('vector_unknown_type', 'procedure Main; var V: Single5; begin end;', 'numeric vector type'),
    @('vector_bool_type', 'procedure Main; var V: Boolean3; begin end;', 'numeric vector type'),
    @('intrinsic_reserved', 'function Dot: Integer; begin Result := 1; end; procedure Main; begin end;', 'reserved'),
    @('intrinsic_min_arity', 'procedure Main; var I: Integer; begin I := Min(1); end;', 'expects 2 arguments'),
    @('intrinsic_max_arity', 'procedure Main; var I: Integer; begin I := Max(1,2,3); end;', 'expects 2 arguments'),
    @('intrinsic_clamp_arity', 'procedure Main; var I: Integer; begin I := Clamp(1,2); end;', 'expects 3 arguments'),
    @('intrinsic_abs_arity', 'procedure Main; var I: Integer; begin I := Abs(1,2); end;', 'expects 1 arguments'),
    @('intrinsic_sqrt_arity', 'procedure Main; var S: Single; begin S := Sqrt(); end;', 'expects 1 arguments'),
    @('intrinsic_min_bool', 'procedure Main; var B: Boolean; begin B := Min(True,False); end;', 'numeric operands'),
    @('intrinsic_abs_bool', 'procedure Main; var B: Boolean; begin B := Abs(True); end;', 'numeric value'),
    @('intrinsic_sqrt_bool', 'procedure Main; var S: Single; begin S := Sqrt(False); end;', 'numeric value'),
    @('intrinsic_dot_scalar', 'procedure Main; var S: Single; begin S := Dot(1,2); end;', 'two numeric vectors'),
    @('intrinsic_dot_width', 'procedure Main; var S: Single; begin S := Dot(Single2(1),Single3(1)); end;', 'same width'),
    @('intrinsic_clamp_width', 'procedure Main; var V: Single3; begin V := Clamp(Single3(1),Single2(0),1); end;', 'Cannot convert')
)
foreach ($case in $vectorFailures) { Test-Failure $case[0] $case[1] $case[2] }
Test-Success 'vector_buffer_layout' 'var [Binding(0,0)] Data: array of Single3; procedure Main; begin end;'
Test-Success 'vector_push_layout' 'var [PushConstant] P: record V: Single3; end; procedure Main; begin end;'

$coreAssembly = Invoke-Tool $SpirvDis @((Join-Path $cases 'empty.spv'))
Assert-True ($coreAssembly.Code -eq 0 -and $coreAssembly.Out -notmatch '\bOpExtInstImport\b') 'Core-only shader imported an unused instruction set'
$mathAssembly = Invoke-Tool $SpirvDis @((Join-Path $cases 'intrinsic_edges.spv'))
Assert-True ($mathAssembly.Code -eq 0 -and ([regex]::Matches($mathAssembly.Out, '\bOpExtInstImport\b')).Count -eq 1 -and $mathAssembly.Out -match 'GLSL.std.450') 'Math instruction set was not imported exactly once'
$script:checks += 2
