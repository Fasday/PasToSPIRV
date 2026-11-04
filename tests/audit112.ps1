# Re-audit 1.1.2 regressions (loaded by scripts/test.ps1).

# Integer negation/Abs are emitted as 0 - X: OpSNegate was optimized as no-wrap by a driver.
Test-Success 'a112_negate_wrap' ([IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\negate_wrap.pas'))) 'OpISub'
$negateAsm = Invoke-Tool $SpirvDis @((Join-Path $cases 'a112_negate_wrap.spv'))
Assert-True ($negateAsm.Out -notmatch '\bOpSNegate\b') 'Integer negation still uses OpSNegate'
Test-Extended 'a112_negate_wide' '[Vulkan12] procedure Main; var A: Int64; begin A := -9223372036854775807; A := -A; A := Abs(A); end;' 'OpISub'
$negateAsm = Invoke-Tool $SpirvDis @((Join-Path $cases 'a112_negate_wide.spv'))
Assert-True ($negateAsm.Out -notmatch '\bOpSNegate\b') 'Int64 negation still uses OpSNegate'

# Untyped constant trees may adapt to another integer type only when they did not wrap.
Test-Extended 'a112_exact_widen' '[Vulkan12] procedure Main; var L: Int64; U: UInt64; B: Byte; W: Word; begin L := 100 * 1000; L := 1 shl 20; L := -(2147483647) - 1; U := 4000000000 + 1; B := 200 + 55; W := 1 shl 15; L := (-8) div 3; end;'
Test-Success 'a112_wrap_same_type' 'const N = 2147483647 + 1; procedure Main; var I: Integer; begin I := N; I := 2147483647 + 1; end;' 'OpStore'
$wrapFailures = @(
    @('a112_wrap_mul', '[Vulkan12] procedure Main; var L: Int64; begin L := 100000 * 100000; end;', 'wraps in Integer'),
    @('a112_wrap_shl_count', '[Vulkan12] procedure Main; var L: Int64; begin L := 1 shl 40; end;', 'wraps in Integer'),
    @('a112_wrap_add', '[Vulkan12] procedure Main; var L: Int64; begin L := 2147483647 + 1; end;', 'wraps in Integer'),
    @('a112_wrap_negate', '[Vulkan12] procedure Main; var L: Int64; begin L := -(-2147483648); end;', 'wraps in Integer'),
    @('a112_wrap_neg_shr', '[Vulkan12] procedure Main; var L: Int64; begin L := (-8) shr 1; end;', 'wraps in Integer'),
    @('a112_wrap_byte', '[Vulkan12] procedure Main; var B: Byte; begin B := 200 + 100; end;', 'wraps in Integer|Cannot convert'),
    @('a112_wrap_const_decl', 'const N = 100000 * 100000; [Vulkan12] procedure Main; var L: Int64; begin L := N; end;', 'Cannot convert'),
    @('a112_wrap_typed_const', 'const C: Int64 = 100000 * 100000; [Vulkan12] procedure Main; begin end;', 'wraps in Integer'),
    @('a112_wrap_case_label', '[Vulkan12] procedure Main; var L: Int64; begin L := 0; case L of 100000 * 100000: begin end; end; end;', 'wraps in Integer'),
    @('a112_wrap_argument', 'function F(V: Int64): Int64; begin Result := V; end; [Vulkan12] procedure Main; var L: Int64; begin L := F(65536 * 65536); end;', 'wraps in Integer'),
    @('a112_wrap_table', 'type T = array[0..0] of Int64; const A: T = (65536 * 65536); [Vulkan12] procedure Main; begin end;', 'wraps in Integer'),
    @('a112_wrap_mixed', '[Vulkan12] procedure Main; var L: Int64; begin L := (65536 * 65536) + $100000000; end;', 'wraps in Integer')
)
foreach ($n in $wrapFailures) { Test-Failure $n[0] $n[1] $n[2] }

if (-not $SkipDelphiTests) {
    # 1.1 scalar names were valid bindings unit names before 1.1; host types are System-qualified.
    $unitDir = Join-Path $cases 'a112-unit-names'
    New-Item -ItemType Directory -Force $unitDir | Out-Null
    $shader = Join-Path $unitDir 'mixed.pas'
    [IO.File]::WriteAllText($shader, (Get-Content (Join-Path $root 'tests\fixtures\extended_layout.pas') -Raw), $utf8)
    foreach ($unitName in @('Byte', 'Word', 'Int64', 'UInt64', 'Double')) {
        $bindings = Join-Path $unitDir "$unitName.pas"
        $generated = Invoke-Tool $compiler @($shader, '-o', (Join-Path $unitDir "$unitName.spv"), '--bindings', $bindings)
        Assert-True ($generated.Code -eq 0) "Bindings unit $unitName was not generated: $($generated.Err)"
        $program = Join-Path $unitDir "Use${unitName}Unit.dpr"
        [IO.File]::WriteAllText($program, "program Use${unitName}Unit;`n{`$APPTYPE CONSOLE}`nuses $unitName in '$unitName.pas';`nbegin`n  PTS_ValidateLayouts;`n  Writeln('PASS');`nend.", $utf8)
        & (Join-Path $root 'scripts\build.ps1') -Project $program -OutputDirectory $unitDir | Out-Null
        $run = Invoke-Tool (Join-Path $unitDir "Use${unitName}Unit.exe") @()
        Assert-True ($run.Code -eq 0 -and $run.Out -match 'PASS') "Generated unit named $unitName does not compile/validate"
        $script:checks++
    }
}
