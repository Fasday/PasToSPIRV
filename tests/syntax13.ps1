# Language 1.3 (Delphi syntax group 2) regressions (loaded by scripts/test.ps1).

$e = 'type TMode = (mA, mB, mC); TModes = set of TMode; '
Test-Success 's13_group2' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\syntax_group2.pas'))) 'OpVectorShuffle'
Test-Extended 's13_group2_refs' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\syntax_group2_refs.pas'))) 'OpFunctionCall'
Test-Success 's13_enum_explicit_values' 'type TOp = (opA = 2, opB, opC = 10); procedure Main; var O: TOp; I: Integer; begin O := opB; I := Ord(O) + Ord(High(TOp)) + Ord(Low(TOp)); end;' 'OpStore'
Test-Success 's13_enum_value_expression' 'type TOp = (opA = 2, opB = Ord(opA) * 4); procedure Main; var I: Integer; begin I := Ord(opB); end;' 'OpStore'
Test-Success 's13_enum_low_variable' ($e + 'procedure Main; var M: TMode; I: Integer; begin M := mB; I := Ord(High(M)) + Low(I); end;') 'OpStore'
Test-Success 's13_enum_cast_between' ($e + 'type TOther = (oA, oB); procedure Main; var M: TMode; O: TOther; begin M := mB; O := TOther(M); end;') 'OpStore'
Test-Success 's13_set_empty_compare' ($e + 'procedure Main; var S: TModes; B: Boolean; begin S := []; B := (S = []) and ([] <= S); S := S + []; end;') 'OpIEqual'
Test-Success 's13_set_variable_range' ($e + 'procedure Main; var S: TModes; L, H: TMode; begin L := mA; H := TMode(GlobalInvocationID.X mod 3); S := [L..H, mC]; end;') 'OpShiftLeftLogical'
Test-Success 's13_in_enum_dynamic' ($e + 'procedure Main; var M, N: TMode; B: Boolean; begin M := mA; N := mC; B := M in [N, mB..N]; end;') 'OpLogicalOr'
Test-Extended 's13_if_literal_adapt' '[Vulkan12] procedure Main; var B: Byte; begin B := if GlobalInvocationID.X = 0 then 200 else 1; end;' 'OpSelect'
Test-Success 's13_if_nested' 'procedure Main; var I: Integer; begin I := if GlobalInvocationID.X = 0 then 1 else if GlobalInvocationID.X = 1 then 2 else 3; end;' 'OpSelect'
Test-Success 's13_if_constant_fold' 'const K = if 2 > 1 then 7 else 9; procedure Main; var I: Integer; begin I := K; end;' 'OpStore'
Test-Success 's13_swizzle_rgba' 'procedure Main; var C: Single4; G: Single3; begin C := Single4(1); G := C.bgr; C.rgb := G; end;' 'OpVectorShuffle'
Test-Success 's13_multidim_record' 'type R = record M: array[0..1, 0..2] of Single; end; procedure Main; var X: R; begin X := Default(R); X.M[1, 2] := 3; end;' 'OpAccessChain'
Test-Success 's13_overload_literal' 'function F(A: Cardinal): Integer; overload; begin Result := 1; end; function F(A: Single): Integer; overload; begin Result := 2; end; procedure Main; var I: Integer; begin I := F(5); end;' 'OpFunctionCall'
Test-Success 's13_overload_nested' 'procedure Main; var S: Integer; procedure Add(V: Integer); overload; begin S := S + V; end; procedure Add(V: Single); overload; begin S := S + Integer(V); end; begin S := 0; Add(1); Add(2.5); end;' 'OpFunctionCall'
Test-Success 's13_nested_in_function' 'function F(X: Integer): Integer; var T: Integer; function Half: Integer; begin Result := X div 2; end; begin T := Half; F := T + Half; end; procedure Main; var I: Integer; begin I := F(4); end;' 'OpFunctionCall'
Test-Success 's13_nested_outer_name' 'function F: Integer; procedure SetIt; begin F := 5; end; begin SetIt; end; procedure Main; var I: Integer; begin I := F; end;' 'OpFunctionCall'
Test-Success 's13_nested_sibling' 'procedure Main; var A: Integer; procedure P; begin A := A + 1; end; procedure Q; begin P; P; end; begin A := 0; Q; end;' 'OpFunctionCall'
Test-Success 's13_directive_names' 'procedure Main; var Forward, Overload: Integer; begin Forward := 1; Overload := Forward; end;' 'OpStore'

$syntax13Failures = @(
    @('s13_enum_arith', ($e + 'procedure Main; var M: TMode; begin M := mA + 1; end;'), 'Incompatible types'),
    @('s13_enum_assign_int', ($e + 'procedure Main; var M: TMode; begin M := 1; end;'), 'Cannot convert Integer to TMode'),
    @('s13_enum_mixed', ($e + 'type TOther = (oA, oB); procedure Main; var B: Boolean; begin B := mA = oA; end;'), 'Incompatible types'),
    @('s13_enum_resource', ($e + 'var [Binding(0,0)] D: array of TMode; procedure Main; begin end;'), 'Enumerations and sets are not supported'),
    @('s13_enum_push', ($e + 'var [PushConstant] P: record M: TMode; end; procedure Main; begin end;'), 'Enumerations and sets are not supported'),
    @('s13_enum_anonymous', 'procedure Main; var M: (a, b); begin end;', 'named types'),
    @('s13_enum_duplicate', 'type A = (x, y); B = (y, z); procedure Main; begin end;', 'Duplicate identifier'),
    @('s13_enum_type_name', 'type A = (A, B); procedure Main; begin end;', 'Duplicate identifier'),
    @('s13_enum_negative', 'type A = (x = -1); procedure Main; begin end;', '0\.\.2147483647'),
    @('s13_enum_float_cast', ($e + 'procedure Main; var S: Single; begin S := Single(mA); end;'), 'Cannot convert'),
    @('s13_enum_sizeof', ($e + 'procedure Main; var I: Integer; begin I := SizeOf(TMode); end;'), 'std430'),
    @('s13_enum_qualified_unknown', ($e + 'procedure Main; var M: TMode; begin M := TMode.mZ; end;'), 'is not a value of TMode'),
    @('s13_enum_odd', ($e + 'procedure Main; var B: Boolean; begin B := Odd(mA); end;'), 'scalar integer'),
    @('s13_enum_case_mixed', ($e + 'procedure Main; var M: TMode; begin M := mA; case M of 1: begin end; end; end;'), 'Cannot convert'),
    @('s13_set_large', 'type T = (a, b = 32); S = set of T; procedure Main; begin end;', '0\.\.31'),
    @('s13_set_integer', 'type S = set of Integer; procedure Main; begin end;', 'enumeration element type'),
    @('s13_set_mixed', ($e + 'type TOther = (oA, oB); procedure Main; var B: Boolean; begin B := [mA] = [oA]; end;'), 'Incompatible types'),
    @('s13_set_less', ($e + 'procedure Main; var S: TModes; B: Boolean; begin S := []; B := S < [mA]; end;'), 'Set operators'),
    @('s13_set_integer_value', ($e + 'procedure Main; var S: TModes; begin S := [1, 2]; end;'), 'enumeration elements'),
    @('s13_set_infer', 'procedure Main; begin var S := []; end;', 'Cannot infer a set type'),
    @('s13_include_nonset', 'procedure Main; var I: Integer; begin I := 0; Include(I, 1); end;', 'require a set variable'),
    @('s13_include_wrong_enum', ($e + 'type TOther = (oA, oB); procedure Main; var S: TModes; begin S := []; Include(S, oA); end;'), 'Cannot convert'),
    @('s13_include_reserved', 'procedure Main; var Include: Integer; begin end;', 'reserved'),
    @('s13_in_float', 'procedure Main; var B: Boolean; begin B := 1.5 in [1]; end;', 'integer or enumeration value'),
    @('s13_in_integer_set_value', ($e + 'procedure Main; var S: TModes; I: Integer; B: Boolean; begin S := []; I := 0; B := I in S; end;'), 'Integer membership'),
    @('s13_in_enum_wrong_set', ($e + 'type TOther = (oA, oB); procedure Main; var B: Boolean; begin B := oA in [mA]; end;'), 'Cannot convert'),
    @('s13_if_types', 'procedure Main; var I: Integer; begin I := if GlobalInvocationID.X = 0 then 1 else True; end;', 'Incompatible types in if expression'),
    @('s13_if_condition', 'procedure Main; var I: Integer; begin I := if 1 then 2 else 3; end;', 'condition must have type Boolean'),
    @('s13_if_operand', 'procedure Main; var I: Integer; begin I := 1 + if GlobalInvocationID.X = 0 then 1 else 2; end;', 'must be parenthesized'),
    @('s13_if_no_else', 'procedure Main; var I: Integer; begin I := if GlobalInvocationID.X = 0 then 1; end;', 'Expected "else"'),
    @('s13_if_procedure', 'procedure P; begin end; procedure Main; var I: Integer; begin I := if GlobalInvocationID.X = 0 then P else 1; end;', 'need a value'),
    @('s13_if_out_conditional', 'function Init(out X: Integer): Integer; begin X := 1; Result := 0; end; [Vulkan12] procedure Main; var X, Y: Integer; begin Y := if GlobalInvocationID.X = 0 then Init(X) else 0; Y := X; end;', 'uninitialized'),
    @('s13_swizzle_mixed', 'procedure Main; var V: Single4; W: Single2; begin V := Single4(0); W := V.XG; end;', 'one set'),
    @('s13_swizzle_range', 'procedure Main; var V: Single2; W: Single2; begin V := Single2(0); W := V.XZ; end;', 'not available'),
    @('s13_swizzle_long', 'procedure Main; var V: Single4; begin V := Single4(0); V := V.XYZWX; end;', 'at most four'),
    @('s13_swizzle_repeat_write', 'procedure Main; var V: Single4; begin V := Single4(0); V.XX := Single2(1); end;', 'cannot repeat'),
    @('s13_swizzle_through', 'procedure Main; var V: Single4; begin V := Single4(0); V.XY.X := 1; end;', 'through a swizzle'),
    @('s13_swizzle_uninit', 'procedure Main; var V: Single4; begin V.XY := Single2(1); end;', 'uninitialized'),
    @('s13_swizzle_var_arg', 'procedure P(var X: Single2); begin X := Single2(0); end; [Vulkan12] procedure Main; var V: Single4; begin V := Single4(0); P(V.XY); end;', 'writable function-local lvalues'),
    @('s13_swizzle_scalar', 'procedure Main; var S: Single; T: Single2; begin S := 1; T := S.XX; end;', 'requires a vector'),
    @('s13_multidim_bounds', 'procedure Main; var A: array[0..1, 0..3] of Integer; I: Integer; begin I := 0; A[0, 5] := I; end;', 'out of bounds'),
    @('s13_multidim_lower', 'type T = array[0..1, 1..2] of Integer; procedure Main; begin end;', 'zero lower bound'),
    @('s13_record_const_order', 'type R = record A, B: Integer; end; const C: R = (B: 1; A: 2); procedure Main; begin end;', 'Expected field "A"'),
    @('s13_record_const_missing', 'type R = record A, B: Integer; end; const C: R = (A: 1); procedure Main; begin end;', 'between record fields'),
    @('s13_record_const_write', 'type R = record A: Integer; end; const C: R = (A: 1); procedure Main; begin C.A := 2; end;', 'read-only'),
    @('s13_vector_const_count', 'const V: Single3 = (1, 2, 3, 4); procedure Main; begin end;', 'after the vector components'),
    @('s13_forward_missing', 'function G: Integer; forward; procedure Main; begin end;', 'has no definition'),
    @('s13_forward_mismatch', 'function G(A: Integer): Integer; forward; function G(A: Single): Integer; begin Result := 1; end; procedure Main; begin end;', 'differs from its forward declaration'),
    @('s13_forward_names', 'function G(A: Integer): Integer; forward; function G(B: Integer): Integer; begin Result := B; end; procedure Main; begin end;', 'differs from its forward declaration'),
    @('s13_forward_twice', 'function G: Integer; forward; function G: Integer; forward; procedure Main; begin end;', 'Duplicate identifier'),
    @('s13_forward_recursion', 'function G(A: Integer): Integer; forward; function F(A: Integer): Integer; begin Result := G(A); end; function G(A: Integer): Integer; begin Result := F(A); end; procedure Main; begin end;', 'Recursion is not supported'),
    @('s13_forward_main', 'procedure Main; forward; procedure Main; begin end;', 'Expected "begin"'),
    @('s13_overload_directive', 'function F(A: Integer): Integer; overload; begin Result := A; end; function F(A: Single): Integer; begin Result := 1; end; procedure Main; begin end;', 'mark every version with overload'),
    @('s13_overload_same_types', 'function F(A: Integer): Integer; overload; begin Result := A; end; function F(B: Integer): Single; overload; begin Result := 1; end; procedure Main; begin end;', 'already exists'),
    @('s13_overload_ambiguous', 'function F(A: Integer; B: Single): Integer; overload; begin Result := 1; end; function F(A: Single; B: Integer): Integer; overload; begin Result := 2; end; procedure Main; var I: Integer; begin I := F(1, 1); end;', 'Ambiguous call'),
    @('s13_overload_no_match', 'function F(A: Integer): Integer; overload; begin Result := 1; end; function F(A: Single): Integer; overload; begin Result := 2; end; procedure Main; var I: Integer; begin I := F(True); end;', 'No overload'),
    @('s13_overload_ref_mix', 'procedure P(var X: Integer); overload; begin X := 1; end; procedure P(X: Single); overload; begin end; [Vulkan12] procedure Main; var I: Integer; begin I := 0; P(I); end;', 'differ in var/out'),
    @('s13_nested_shadow', 'procedure Main; var A: Integer; procedure P(A: Integer); begin end; begin end;', 'Duplicate identifier'),
    @('s13_nested_global_name', 'procedure G; begin end; procedure Main; procedure G; begin end; begin end;', 'shadowing'),
    @('s13_nested_outside', 'procedure Outer; procedure Inner; begin end; begin Inner; end; procedure Main; begin Inner; end;', 'Unknown identifier'),
    @('s13_nested_later_local', 'procedure Main; procedure P; begin A := 1; end; var A: Integer; begin end;', 'Unknown identifier'),
    @('s13_nested_uninit', 'procedure Main; var X, Y: Integer; procedure P; begin Y := X; end; begin P; X := 1; end;', 'reads "X", which may be uninitialized'),
    @('s13_nested_conditional_write', 'procedure Main; var X, Y: Integer; procedure P; begin if GlobalInvocationID.X = 0 then X := 1; end; begin P; Y := X; end;', 'uninitialized'),
    @('s13_nested_var_param', 'procedure Outer(var V: Integer); procedure P; begin V := 1; end; begin P; end; [Vulkan12] procedure Main; begin end;', 'var/out parameter "V"'),
    @('s13_nested_counter', 'procedure Main; var I, S: Integer; procedure P; begin S := S + I; end; begin S := 0; for I := 0 to 3 do P; end;', 'shared with a nested routine'),
    @('s13_nested_recursion', 'procedure Main; procedure P; begin Main; end; begin P; end;', 'Main cannot be called'),
    @('s13_nested_outer_recursion', 'procedure Outer; procedure P; begin Outer; end; begin P; end; procedure Main; begin Outer; end;', 'Recursion is not supported'),
    @('s13_nested_forward', 'procedure Main; procedure P; forward; begin end;', 'cannot be forward-declared'),
    @('s13_nested_atomic', 'var [Binding(0,0)] D: array of Cardinal; procedure Main; procedure P; var C: Cardinal; begin C := AtomicAdd(D[0], 1); end; begin P; end;', 'only available in Main')
)
foreach ($n in $syntax13Failures) { Test-Failure $n[0] $n[1] $n[2] }

# The OpSelect path never evaluates impure branches: a buffer read stays behind a branch.
Test-Success 's13_if_lazy' 'var [Binding(0,0)] D: array of Integer; procedure Main; var I: Integer; begin I := if GlobalInvocationID.X < 4 then D[GlobalInvocationID.X] else 0; end;' 'OpPhi'
$lazyAsm = Invoke-Tool $SpirvDis @((Join-Path $cases 's13_if_lazy.spv'))
Assert-True (-not ($lazyAsm.Out -match '\bOpSelect\b')) 'An impure if-expression branch must not use OpSelect'
