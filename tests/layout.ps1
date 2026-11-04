# Loaded by scripts/test.ps1. Expected layouts are independent std430 constants.

function Align-Expected([int]$Size, [int]$Alignment) {
    return [int]([Math]::Ceiling($Size / [double]$Alignment) * $Alignment)
}

$layoutNumber = 0
foreach ($base in @('Integer', 'Cardinal', 'Single')) {
    foreach ($width in @(1, 2, 3, 4)) {
        $type = $base
        if ($width -gt 1) { $type = "$base$width" }
        $size = $width * 4
        $alignment = 4
        if ($width -eq 2) { $alignment = 8 }
        if ($width -ge 3) { $alignment = 16 }
        $stride = Align-Expected $size $alignment
        $name = "layout_value_$layoutNumber"
        Test-Success $name "var [Binding(0,0)] Data: array of $type; [PushConstant] P: record V: $type; Tail: Cardinal; end; procedure Main; begin Data[0] := P.V; end;"
        $meta = Get-Content (Join-Path $cases "$name.json") -Raw | ConvertFrom-Json
        Assert-True ($meta.format_version -eq 2 -and $meta.layout -eq 'std430') 'Unexpected reflection ABI version'
        Assert-True ($meta.buffers[0].element_size -eq $size) "$type value size"
        Assert-True ($meta.buffers[0].element_alignment -eq $alignment) "$type alignment"
        Assert-True ($meta.buffers[0].array_stride -eq $stride) "$type runtime stride"
        Assert-True ($meta.push_constants[0].members[1].offset -eq $size) "$type scalar packing"
        Assert-True ($meta.push_constants[0].size -eq (Align-Expected ($size + 4) $alignment)) "$type push block size"

        $name = "layout_array_$layoutNumber"
        Test-Success $name "type TValues = array[0..2] of $type; var [Binding(0,0)] Data: array of TValues; [PushConstant] P: record Values: TValues; Count: Cardinal; end; procedure Main; begin Data[0] := P.Values; end;"
        $meta = Get-Content (Join-Path $cases "$name.json") -Raw | ConvertFrom-Json
        $array = $meta.types | Where-Object { $_.name -eq 'TValues' }
        Assert-True ($array.array_stride -eq $stride -and $array.length -eq 3) "$type static array stride/length"
        Assert-True ($array.size -eq (3 * $stride)) "$type static array size"
        Assert-True ($meta.buffers[0].array_stride -eq (3 * $stride)) "$type array-valued buffer stride"
        Assert-True ($meta.push_constants[0].members[1].offset -eq (3 * $stride)) "$type field after array"
        $layoutNumber++
        $script:checks += 2
    }
}

$meta = Get-Content (Join-Path $cases 'layout_records.json') -Raw | ConvertFrom-Json
$item = $meta.types | Where-Object { $_.name -eq 'TItem' }
$weights = $meta.types | Where-Object { $_.name -eq 'TWeights' }
$options = $meta.types | Where-Object { $_.name -eq 'TOptions' }
Assert-True ($item.size -eq 64 -and $item.alignment -eq 16) 'Nested record size/alignment'
Assert-True (($item.members.offset -join ',') -eq '0,12,16,48') 'Nested record offsets'
Assert-True ($weights.array_stride -eq 16 -and $weights.size -eq 32) 'Nested vector3 array layout'
Assert-True ($item.members[2].type_id -eq $weights.id) 'Nested type reference was lost'
Assert-True (($options.members.offset -join ',') -eq '0,4,16,28,32') 'Push record offsets'
Assert-True ($options.size -eq 48 -and $meta.push_constants[0].size -eq 48) 'Push record size'
Assert-True ($meta.buffers[2].element_size -eq 12 -and $meta.buffers[2].array_stride -eq 16) 'Vector3 resource slot padding'
$script:checks++

$layoutSuccesses = @(
    @('layout_shared_push_type', 'type TData = record V: Single3; Tail: Single; end; var [Binding(0,0)] Data: array of TData; [PushConstant] P: TData; procedure Main; begin Data[0] := P; end;'),
    @('layout_aliases', 'type TCount = Cardinal; TData = record Value: TCount; end; TAlias = TData; var [Binding(0,0)] Data: array of TAlias; procedure Main; var R: TData; begin R := Default(TAlias); R.Value := TCount(4); Data[0] := R; end;'),
    @('layout_nested_padding', 'type TInner = record V: Single2; Tail: Single; end; TOuter = record Head: Single; Inner: TInner; Position: Single3; Tag: Cardinal; end; var [Binding(0,0)] Data: array of TOuter; procedure Main; begin Data[0].Inner.Tail := 2; end;'),
    @('layout_nested_array', 'type TRow = array[0..2] of Single2; TMatrix = array[0..1] of TRow; var [Binding(0,0)] Data: array of TMatrix; procedure Main; begin Data[0][1][2].Y := 5; end;'),
    @('layout_inline_record', 'var [Binding(0,0)] Data: array of record V: Single3; Weight: Single; end; procedure Main; begin Data[0].Weight := 1; end;'),
    @('layout_writeonly_field', 'type TData = record V: Single3; Values: array[0..1] of Integer; end; var [Binding(0,0), WriteOnly] Data: array of TData; procedure Main; begin Data[0].V.Y := 2; Data[0].Values[1] := 3; end;'),
    @('layout_default_scalar', 'procedure Main; var I: Integer; V: Single3; B: Boolean; begin I := Default(Integer); V := Default(Single3); B := Default(Boolean); end;'),
    @('layout_default_record_return', 'type TData = record V: Single3; N: Cardinal; end; function F: TData; begin Result := Default(TData); Result.N := 7; end; procedure Main; var R: TData; begin R := F(); end;'),
    @('layout_array_alias', 'type TArray = array[0..2] of Integer; TAlias = TArray; procedure Main; var A: TArray; B: TAlias; begin A := Default(TArray); B := A; B[1] := 3; end;'),
    @('layout_distinct_arrays', 'type TFirst = array[0..1] of Single3; TSecond = array[0..1] of Single3; var [Binding(0,0)] A: array of TFirst; [Binding(0,1)] B: array of TSecond; procedure Main; begin A[0] := Default(TFirst); B[0] := Default(TSecond); end;'),
    @('layout_bool_local', 'type TData = record B: Boolean; Values: array[0..1] of Boolean; end; procedure Main; var R: TData; begin R := Default(TData); R.Values[1] := True; R.B := R.Values[1]; end;'),
    @('layout_push_exact128', 'var [PushConstant] P: record V: array[0..7] of Single3; end; procedure Main; var V: Single3; begin V := P.V[7]; end;')
)
foreach ($case in $layoutSuccesses) { Test-Success $case[0] $case[1] }
$nested = Get-Content (Join-Path $cases 'layout_nested_padding.json') -Raw | ConvertFrom-Json
$outer = $nested.types | Where-Object { $_.name -eq 'TOuter' }
Assert-True ($outer.size -eq 48 -and ($outer.members.offset -join ',') -eq '0,8,32,44') 'Nested record padding oracle'
$matrix = Get-Content (Join-Path $cases 'layout_nested_array.json') -Raw | ConvertFrom-Json
$row = $matrix.types | Where-Object { $_.name -eq 'TRow' }
$mat = $matrix.types | Where-Object { $_.name -eq 'TMatrix' }
Assert-True ($row.array_stride -eq 8 -and $mat.array_stride -eq 24 -and $mat.size -eq 48) 'Nested std430 array strides'
$script:checks += 2

$layoutFailures = @(
    @('aggregate_record_identity', 'type A = record V: Integer; end; B = record V: Integer; end; procedure Main; var X: A; Y: B; begin X := Default(A); Y := X; end;', 'Cannot convert'),
    @('aggregate_array_identity', 'type A = array[0..1] of Integer; B = array[0..1] of Integer; procedure Main; var X: A; Y: B; begin X := Default(A); Y := X; end;', 'Cannot convert'),
    @('aggregate_argument_identity', 'type A = record V: Integer; end; B = record V: Integer; end; function F(V: A): A; begin Result := V; end; procedure Main; var X: B; begin X := Default(B); X := F(X); end;', 'Cannot convert'),
    @('aggregate_partial_record', 'type TData = record V: Integer; end; procedure Main; var R: TData; begin R.V := 1; end;', 'initialized as a whole'),
    @('aggregate_partial_array', 'type TData = array[0..1] of Integer; procedure Main; var A: TData; begin A[0] := 1; end;', 'initialized as a whole'),
    @('aggregate_read_uninitialized', 'type TData = record V: Integer; end; procedure Main; var R: TData; I: Integer; begin I := R.V; end;', 'uninitialized'),
    @('aggregate_result_uninitialized', 'type TData = record V: Integer; end; function F: TData; begin end; procedure Main; begin end;', 'uninitialized Result'),
    @('aggregate_result_partial', 'type TData = record V: Integer; end; function F: TData; begin Result.V := 1; end; procedure Main; begin end;', 'initialized as a whole'),
    @('aggregate_unknown_field', 'type TData = record V: Integer; end; procedure Main; var R: TData; begin R := Default(TData); R.Missing := 1; end;', 'Unknown record field'),
    @('aggregate_constructor', 'type TData = record V: Integer; end; procedure Main; var R: TData; begin R := TData(1); end;', 'use Default'),
    @('aggregate_default_unknown', 'procedure Main; begin Default(Missing); end;', 'Unknown identifier'),
    @('aggregate_default_type_unknown', 'procedure Main; var I: Integer; begin I := Default(Missing); end;', 'declared aggregate type'),
    @('aggregate_recursive', 'type TData = record V: TData; end; procedure Main; begin end;', 'Recursive or forward'),
    @('aggregate_forward', 'type TFirst = TSecond; TSecond = record V: Integer; end; procedure Main; begin end;', 'declared aggregate type'),
    @('aggregate_duplicate_type', 'type TData = Integer; tdata = Cardinal; procedure Main; begin end;', 'Duplicate type'),
    @('aggregate_duplicate_field', 'type TData = record V: Integer; v: Single; end; procedure Main; begin end;', 'Duplicate record field'),
    @('aggregate_type_reserved', 'type Single3 = record V: Integer; end; procedure Main; begin end;', 'reserved'),
    @('aggregate_type_shadow', 'type TData = record V: Integer; end; procedure Main; var TData: Integer; begin end;', 'reserved'),
    @('aggregate_empty_record', 'type TData = record end; procedure Main; begin end;', 'must not be empty'),
    @('aggregate_array_low_bound', 'type TData = array[1..2] of Integer; procedure Main; begin end;', 'zero lower bound'),
    @('aggregate_array_large', 'type TData = array[0..65536] of Integer; procedure Main; begin end;', '65536 elements'),
    @('aggregate_array_runtime_local', 'procedure Main; var A: array of Integer; begin end;', 'static array'),
    @('aggregate_array_negative_index', 'type TData = array[0..1] of Integer; procedure Main; var A: TData; begin A := Default(TData); A[-1] := 3; end;', 'out of bounds'),
    @('aggregate_array_high_index', 'type TData = array[0..1] of Integer; procedure Main; var A: TData; begin A := Default(TData); A[2] := 3; end;', 'out of bounds'),
    @('aggregate_array_float_index', 'type TData = array[0..1] of Integer; procedure Main; var A: TData; begin A := Default(TData); A[0.5] := 3; end;', 'indices must have type'),
    @('aggregate_array_bool_index', 'type TData = array[0..1] of Integer; procedure Main; var A: TData; begin A := Default(TData); A[True] := 3; end;', 'indices must have type'),
    @('aggregate_array_rvalue_dynamic', 'type TData = array[0..1] of Integer; function F: TData; begin Result := Default(TData); end; procedure Main; var I: Integer; begin I := 0; I := F()[I]; end;', 'addressable array variable'),
    @('aggregate_operator', 'type TData = record V: Integer; end; procedure Main; var R: TData; begin R := Default(TData); R := R + R; end;', 'numeric operands'),
    @('aggregate_comparison', 'type TData = record V: Integer; end; procedure Main; var R: TData; B: Boolean; begin R := Default(TData); B := R = R; end;', 'numeric operands'),
    @('aggregate_boolean_buffer', 'type TData = record Flags: array[0..1] of Boolean; end; var [Binding(0,0)] Data: array of TData; procedure Main; begin end;', 'Boolean is not supported'),
    @('aggregate_boolean_push', 'type TInner = record Flag: Boolean; end; var [PushConstant] P: record Inner: TInner; end; procedure Main; begin end;', 'Boolean is not supported'),
    @('aggregate_push_scalar', 'var [PushConstant] P: Single3; procedure Main; begin end;', 'require a record'),
    @('aggregate_push_too_large', 'var [PushConstant] P: record V: array[0..8] of Single3; end; procedure Main; begin end;', '128 bytes'),
    @('aggregate_readonly_field', 'type TData = record V: Single3; end; var [Binding(0,0),ReadOnly] Data: array of TData; procedure Main; begin Data[0].V.X := 1; end;', 'ReadOnly'),
    @('aggregate_writeonly_field', 'type TData = record V: Single3; end; var [Binding(0,0),WriteOnly] Data: array of TData; procedure Main; var S: Single; begin S := Data[0].V.X; end;', 'WriteOnly'),
    @('aggregate_size_limit', 'type TBig = array[0..65535] of Single4; THuge = array[0..31] of TBig; procedure Main; begin end;', '16 MiB')
)
foreach ($case in $layoutFailures) { Test-Failure $case[0] $case[1] $case[2] }
$chain = 'type T0 = Cardinal; ' + ((1..33 | ForEach-Object { "T$($_) = array[0..0] of T$($_ - 1);" }) -join ' ')
Test-Failure 'aggregate_type_depth' "$chain procedure Main; begin end;" '32 levels'

$bindingsDirectory = Join-Path $cases 'bindings'
New-Item -ItemType Directory -Force -Path $bindingsDirectory | Out-Null
$bindingPath = Join-Path $bindingsDirectory 'LayoutBindings.pas'
$bindingOutput = Join-Path $bindingsDirectory 'layout.spv'
$generated = Invoke-Tool $compiler @((Join-Path $root 'examples\layout_records.pas'), '-o', $bindingOutput, '--bindings', $bindingPath)
Assert-True ($generated.Code -eq 0) "Bindings generation failed: $($generated.Err)"
$validation = Invoke-Tool $SpirvVal @('--target-env', 'vulkan1.0', $bindingOutput)
Assert-True ($validation.Code -eq 0) "Bindings shader is invalid: $($validation.Err)"
if (-not $SkipDelphiTests) {
    & (Join-Path $root 'scripts\build.ps1') -Project (Join-Path $root 'tests\BindingsCheck.dpr')
    $hostCheck = Invoke-Tool (Join-Path $root 'build\bin\BindingsCheck.exe') @()
    Assert-True ($hostCheck.Code -eq 0 -and $hostCheck.Out -match 'PASS:') "Generated host ABI failed: $($hostCheck.Err)"
    $script:checks++
}
else { Write-Warning 'Generated Delphi ABI execution was explicitly skipped (-SkipDelphiTests).' }

foreach ($badName in @('bad-name.pas', '123.pas', 'unit.pas', 'Layouts.txt', 'Default.pas', 'System.pas', 'Integer.pas', 'TPTS_Type0.pas')) {
    $badPath = Join-Path $bindingsDirectory $badName
    $bad = Invoke-Tool $compiler @((Join-Path $cases 'empty.pas'), '-o', (Join-Path $bindingsDirectory 'bad.spv'), '--bindings', $badPath)
    Assert-True ($bad.Code -eq 2) "Invalid bindings filename was accepted: $badName"
    $script:checks++
}
$inputPath = Join-Path $cases 'empty.pas'
$before = [IO.File]::ReadAllText($inputPath)
$collision = Invoke-Tool $compiler @($inputPath, '--bindings', $inputPath)
Assert-True ($collision.Code -eq 2 -and [IO.File]::ReadAllText($inputPath) -eq $before) 'Bindings overwrote the input'
$preserved = Join-Path $bindingsDirectory 'Preserved.pas'
[IO.File]::WriteAllText($preserved, 'keep-bindings', $utf8)
$badSource = Join-Path $cases 'aggregate_partial_record.pas'
$failed = Invoke-Tool $compiler @($badSource, '-o', (Join-Path $bindingsDirectory 'failed.spv'), '--bindings', $preserved)
Assert-True ($failed.Code -eq 1 -and [IO.File]::ReadAllText($preserved) -eq 'keep-bindings') 'Source failure overwrote bindings'
$script:checks += 2
