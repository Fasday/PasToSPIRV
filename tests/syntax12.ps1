# Language 1.2 syntax regressions (loaded by scripts/test.ps1).

Test-Success 's12_features' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\syntax_features.pas'))) 'OpArrayLength'
Test-Success 's12_multi_names' 'type R = record X1, Y1, X2, Y2: Integer; S: Single; end; procedure Main; var A, B, C: Integer; Q: R; begin A := 1; B := 2; C := A + B; Q := Default(R); Q.Y2 := C; end;' 'OpStore'
Test-Success 's12_sibling_inline' 'procedure Main; begin begin var X := 1; X := X + 1; end; begin var X: Single := 2.0; X := X * 2; end; end;' 'OpStore'
Test-Success 's12_inline_loop_init' 'procedure Main; var S: Integer; begin S := 0; while S < 4 do begin var T := S; S := T + 1; end; end;' 'OpLoopMerge'
Test-Success 's12_for_var_typed' 'var [Binding(0,0)] D: array of Cardinal; procedure Main; var N: Cardinal; begin N := 3; for var I: Cardinal := 0 to N do D[I] := I; end;' 'OpULessThanEqual'
Test-Success 's12_local_const_sections' 'procedure Main; const A = 2; var X: Integer; const B: Cardinal = 3; var Y: Cardinal; begin X := A; Y := B; end;' 'OpStore'
Test-Success 's12_local_const_table' 'procedure Main; const T: array[0..2] of Integer = (5, 6, 7); var I: Integer; begin I := T[GlobalInvocationID.X mod 3]; end;' 'OpConstantComposite'
Test-Success 's12_const_builtins' 'type T = array[0..7] of Single3; const N = Length(T) * SizeOf(Single3) + High(T); M = Sqr(4) + Ord(True); procedure Main; var I: Integer; begin I := N + M; end;' 'OpStore'
Test-Extended 's12_low_high_types' '[Vulkan12] procedure Main; var L: Int64; B: Byte; W: Word; begin L := Low(Int64); L := High(Int64); B := High(Byte); W := Low(Word); end;' 'OpStore'
Test-Success 's12_shortcircuit_pure' 'procedure Main; var A, B: Boolean; begin A := GlobalInvocationID.X = 0; B := A and (GlobalInvocationID.Y = 1); B := A or B; end;' 'OpLogicalAnd'
Test-Success 's12_shortcircuit_effect' 'var [Binding(0,0)] D: array of Integer; procedure Main; var B: Boolean; begin B := (GlobalInvocationID.X < 4) and (D[GlobalInvocationID.X] = 0); end;' 'OpPhi'
Test-Success 's12_shortcircuit_div' 'procedure Main; var A, B: Integer; C: Boolean; begin A := 1; B := Integer(GlobalInvocationID.X); C := (B <> 0) and (A div B > 0); end;' 'OpPhi'
Test-Success 's12_complete_paren_directive' 'var [Binding(0,0)] D: array of Integer; procedure Main; var B: Boolean; begin (*$BOOLEVAL ON*) B := (GlobalInvocationID.X < 4) and (D[0] = 0); end;' 'OpLogicalAnd'
Test-Success 's12_shortcircuit_loops' 'var [Binding(0,0)] D: array of Integer; procedure Main; var I: Integer; begin I := 0; while (I < 4) and (D[I] = 0) do Inc(I); repeat Dec(I); until (I <= 0) or (D[I] <> 0); end;' 'OpPhi'
Test-Success 's12_call_without_parens' 'procedure P; begin end; function One: Integer; begin Result := 1; end; procedure Main; var I: Integer; begin P; I := One + One(); end;' 'OpFunctionCall'
Test-Success 's12_function_name_members' 'type T = record A: Integer; end; TA = array[0..1] of Integer; function F: T; begin F := Default(T); F.A := 2; end; function G: TA; begin G := Default(TA); G[1] := 3; end; procedure Main; var V: T; W: TA; begin V := F; W := G; end;' 'OpReturnValue'
Test-Success 's12_inc_shared' 'var [Shared] S: array[0..63] of Cardinal; procedure Main; begin S[LocalInvocationIndex] := 0; Inc(S[LocalInvocationIndex], 3); end;' 'OpIAdd'
Test-Extended 's12_inc_wide' '[Vulkan12] procedure Main; var B: Byte; L: Int64; begin B := 255; Inc(B); L := 0; Dec(L, 5); end;' 'OpISub'
Test-Extended 's12_case_ranges64' '[Vulkan12] procedure Main; var L: Int64; R: Integer; begin L := -1; R := 0; case L of -3..-1: R := 1; 9223372036854775806..9223372036854775807: R := 2; end; end;' 'OpSwitch'

$syntaxFailures = @(
    @('s12_inline_scope', 'procedure Main; var Y: Integer; begin begin var X := 1; end; Y := X; end;', 'Unknown identifier'),
    @('s12_inline_shadow', 'procedure Main; var X: Integer; begin X := 0; begin var X := 1; end; end;', 'Duplicate identifier'),
    @('s12_inline_untyped', 'procedure Main; begin var X; end;', 'needs a type or an initializer'),
    @('s12_inline_procedure_type', 'procedure P; begin end; procedure Main; begin var X := P(); end;', 'infer'),
    @('s12_inline_loop_uninit', 'procedure Main; var S: Integer; begin S := 0; while S < 4 do begin var T: Integer; S := S + T; T := 1; end; end;', 'uninitialized'),
    @('s12_inline_repeat_until_scope', 'procedure Main; begin repeat var Done := True; until Done; end;', 'Unknown identifier'),
    @('s12_for_var_after', 'procedure Main; var Y: Integer; begin for var I := 0 to 3 do begin end; Y := I; end;', 'Unknown identifier'),
    @('s12_for_var_float', 'procedure Main; begin for var I := 0.5 to 3 do begin end; end;', 'integer variable'),
    @('s12_for_var_write', 'procedure Main; begin for var I := 0 to 3 do I := 1; end;', 'active for-loop counter'),
    @('s12_multi_duplicate', 'procedure Main; var A, A: Integer; begin end;', 'Duplicate identifier'),
    @('s12_field_duplicate', 'type R = record A, B, A: Integer; end; procedure Main; begin end;', 'Duplicate record field'),
    @('s12_local_const_shadow', 'const K = 1; procedure Main; const K = 2; begin end;', 'Duplicate identifier'),
    @('s12_local_const_write', 'procedure Main; const K = 2; begin K := 3; end;', 'read-only'),
    @('s12_local_const_leak', 'function F: Integer; const K = 2; begin Result := K; end; procedure Main; var I: Integer; begin I := K; end;', 'Unknown identifier'),
    @('s12_inc_float', 'procedure Main; var F: Single; begin F := 0; Inc(F); end;', 'scalar integer or enumeration variable'),
    @('s12_inc_writeonly', 'var [Binding(0,0),WriteOnly] D: array of Integer; procedure Main; begin Inc(D[0]); end;', 'WriteOnly'),
    @('s12_inc_readonly', 'var [Binding(0,0),ReadOnly] D: array of Integer; procedure Main; begin Inc(D[0]); end;', 'ReadOnly'),
    @('s12_inc_uninit', 'procedure Main; var X: Integer; begin Inc(X); end;', 'uninitialized'),
    @('s12_inc_counter', 'procedure Main; var I: Integer; begin for I := 0 to 2 do Inc(I); end;', 'active for-loop counter'),
    @('s12_inc_table', 'procedure Main; const T: array[0..1] of Integer = (1, 2); begin Inc(T[0]); end;', 'read-only'),
    @('s12_low_vector', 'procedure Main; var V: Single2; J: Integer; begin V := Single2(0); J := Low(V); end;', 'requires a static array'),
    @('s12_sizeof_boolean', 'procedure Main; var I: Integer; begin I := SizeOf(Boolean); end;', 'std430'),
    @('s12_length_buffer_const', 'var [Binding(0,0)] D: array of Integer; procedure Main; const N = Length(D); begin end;', 'constant expression'),
    @('s12_ord_float', 'procedure Main; var I: Integer; begin I := Ord(1.5); end;', 'Ord requires'),
    @('s12_succ_boolean', 'procedure Main; var B: Boolean; begin B := Succ(False); end;', 'scalar integer'),
    @('s12_reserved_length', 'procedure Main; var Length: Integer; begin end;', 'reserved'),
    @('s12_case_reversed', 'procedure Main; begin case 1 of 5..2: begin end; end; end;', 'low bound exceeds'),
    @('s12_case_overlap', 'procedure Main; begin case 1 of 1..5: begin end; 3: begin end; end; end;', 'Duplicate case'),
    @('s12_case_range_budget', 'procedure Main; begin case GlobalInvocationID.X of 0..20000: begin end; end; end;', 'switch budget'),
    @('s12_missing_args', 'function F(V: Integer): Integer; begin Result := V; end; procedure Main; begin F; end;', 'expects 1 arguments'),
    @('s12_shortcircuit_out', 'function Init(out X: Integer): Boolean; begin X := 1; Result := True; end; [Vulkan12] procedure Main; var X: Integer; B: Boolean; begin B := (GlobalInvocationID.X = 0) and Init(X); X := X + 1; end;', 'uninitialized'),
    @('s12_directive_empty', '{$B} procedure Main; begin end;', 'B\+'),
    @('s12_directive_value', '{$BOOLEVAL MAYBE} procedure Main; begin end;', 'BOOLEVAL ON'),
    @('s12_directive_combined', '{$B+,R-} procedure Main; begin end;', 'one \$B'),
    @('s12_directive_other', '{$R+} procedure Main; begin end;', 'directives are not supported')
)
foreach ($n in $syntaxFailures) { Test-Failure $n[0] $n[1] $n[2] }

# {$B+} applies to the following text only; a plain or after {$B-} short-circuits again.
Test-Success 's12_directive_scope' 'var [Binding(0,0)] D: array of Integer; procedure Main; var B: Boolean; begin {$B+} B := (GlobalInvocationID.X < 4) or (D[0] = 0); {$B-} B := (GlobalInvocationID.X < 4) or (D[1] = 0); end;' 'OpPhi'
$scopeAsm = Invoke-Tool $SpirvDis @((Join-Path $cases 's12_directive_scope.spv'))
Assert-True (([regex]::Matches($scopeAsm.Out, '\bOpPhi\b')).Count -eq 1) 'Only the second or must short-circuit'
Assert-True ($scopeAsm.Out -match '\bOpLogicalOr\b') 'The {$B+} or must evaluate completely'
