# Audit 1.4.1 regressions (loaded by scripts/test.ps1).

# The interlock begin/end pair must run exactly once in every invocation that returns
# from Main: no Exit before the block, and the block must be reachable. A conditional
# Discard before it and an Exit after it stay valid.
$interlockHead = 'var [Input,Builtin(FragCoord)] P: Single4; [Binding(0,0),Coherent] T: Image2D_RGBA8; '
$interlockBlock = 'Interlock begin ImageStore(T, Integer2(P.XY), Single4(1.0)); end;'
Test-Success 'a141_interlock_exit_after' ($interlockHead + "[Fragment,PixelInterlockOrdered] procedure Main; begin if P.X < 0.0 then Discard; begin $interlockBlock end; if P.X > 8.0 then Exit; end;") 'OpBeginInvocationInterlockEXT'
Test-Success 'a141_interlock_nested_exit' ($interlockHead + "[Fragment,PixelInterlockOrdered] procedure Main; procedure Leave; begin if P.X < 1.0 then Exit; end; begin Leave; $interlockBlock end;") 'OpEndInvocationInterlockEXT'
foreach ($case in @(
    @('a141_interlock_exit_before', "begin if P.X < 4.0 then Exit; $interlockBlock end;", 'cannot Exit before'),
    @('a141_interlock_exit_in_loop', "var I: Integer; begin for I := 0 to 3 do if P.X < Single(I) then Exit; $interlockBlock end;", 'cannot Exit before'),
    @('a141_interlock_exit_in_block', "begin begin if P.Y > 1.0 then Exit; end; begin $interlockBlock end; end;", 'cannot Exit before'),
    @('a141_interlock_exit_unconditional', "begin Exit; $interlockBlock end;", 'cannot Exit before'),
    @('a141_interlock_unreachable', "begin Discard; $interlockBlock end;", 'unreachable'),
    @('a141_interlock_unreachable_branches', "begin if P.X < 4.0 then Discard else Discard; $interlockBlock end;", 'unreachable'),
    @('a141_interlock_unreachable_block', "begin begin Discard; end; $interlockBlock end;", 'unreachable')
)) {
    Test-Failure $case[0] ($interlockHead + '[Fragment,PixelInterlockOrdered] procedure Main; ' + $case[1]) $case[2]
}
$interlockAsm = Invoke-Tool $SpirvDis @((Join-Path $cases 'a141_interlock_exit_after.spv'))
Assert-True (([regex]::Matches($interlockAsm.Out, '\bOpBeginInvocationInterlockEXT\b')).Count -eq 1 -and
    ([regex]::Matches($interlockAsm.Out, '\bOpEndInvocationInterlockEXT\b')).Count -eq 1) 'Expected exactly one interlock begin/end pair'
$script:checks++

# Inc/Dec read their target; stage outputs are write-only.
Test-Failure 'a141_output_inc' 'var [Output,Location(0)] A: Integer; [Fragment] procedure Main; begin A := 1; Inc(A); end;' 'read the variable: stage outputs'
Test-Failure 'a141_output_dec' 'var [Output,Location(0)] A: Cardinal; [Fragment] procedure Main; begin A := 1; Dec(A, 2); end;' 'read the variable: stage outputs'

# Enumerations and sets remain explicit vector-constructor components, as in 1.3.
Test-Success 'a141_enum_constructor' 'type TMode = (mA, mB, mC); TModes = set of TMode; var [Binding(0,0)] O: array of Integer4; [Binding(0,1)] U: array of Cardinal4; procedure Main; var S: TModes; begin S := [mA, mC]; O[0] := Integer4(mA, mB, mC, mB); U[0] := Cardinal4(S, S, S, S); O[1] := Integer4(Integer2(mB, mC), mA, 4); O[2] := Integer4(mC); end;' 'OpCompositeConstruct'
Test-Failure 'a141_boolean_constructor' 'var [Binding(0,0)] O: array of Integer4; procedure Main; begin O[0] := Integer4(Integer2(1, 2), True, 4); end;' 'numeric components'
$languageMeta = Get-Content (Join-Path $cases 'a141_enum_constructor.json') -Raw | ConvertFrom-Json
Assert-True ($languageMeta.language_version -eq '1.4') 'Reflection language_version must be 1.4'
$script:checks++

if (-not $SkipDelphiTests) {
    $build = Join-Path $root 'scripts\build.ps1'
    $hostConstants = Join-Path $root 'tests\fixtures\host_constants.pas'

    # Host floating-point state: not inherited, restored exactly, no process-wide effects.
    & $build -Project (Join-Path $root 'tests\FloatStateCheck.dpr')
    $state = Invoke-Tool (Join-Path $root 'build\bin\FloatStateCheck.exe') @($hostConstants)
    Assert-True ($state.Code -eq 0 -and $state.Out -match 'PASS:') "Host FP state regression: $($state.Out)$($state.Err)"
    $script:checks++

    # Builds for another host; the compiler output is shown only when the build fails.
    function Invoke-HostBuild([hashtable]$Parameters) {
        $log = New-Object System.Collections.Generic.List[string]
        try { & $build @Parameters | ForEach-Object { $log.Add([string]$_) } }
        catch { throw "$($_.Exception.Message) Target $($Parameters.Target), $($Parameters.Project):`n$($log -join "`n")" }
    }

    # Other hosts of the compiler units. Compile-only: no linker or platform SDK is needed.
    $hostDirectory = Join-Path $cases 'a141-hosts'
    New-Item -ItemType Directory -Force $hostDirectory | Out-Null
    foreach ($target in @(@('win32', 'dcc32'), @('linux64', 'dcclinux64'), @('osx64', 'dccosx64'), @('osxarm64', 'dccosxarm64'),
        @('android64', 'dccaarm64'), @('android', 'dccaarm'), @('iosDevice64', 'dcciosarm64'))) {
        if (-not (& $build -Probe -Target $target[0] -CompilerName $target[1])) {
            Write-Host "SKIP: Delphi target $($target[0]) is not installed."
            continue
        }
        foreach ($unit in @('PTS.Component.pas', 'PTS.Project.pas')) {
            Invoke-HostBuild @{ Project = (Join-Path $root "source\$unit"); Target = $target[0]; CompilerName = $target[1]
                OutputDirectory = $hostDirectory }
        }
        $script:checks++
    }

    # Win32 can run here: the x87 host gives the same SPIR-V and reflection as Win64.
    if (& $build -Probe -Target win32 -CompilerName dcc32) {
        $win32 = Join-Path $hostDirectory 'win32'
        Invoke-HostBuild @{ Target = 'win32'; CompilerName = 'dcc32'; OutputDirectory = $win32 }
        Invoke-HostBuild @{ Project = (Join-Path $root 'tests\FloatStateCheck.dpr'); Target = 'win32'; CompilerName = 'dcc32'
            OutputDirectory = $win32 }
        $state = Invoke-Tool (Join-Path $win32 'FloatStateCheck.exe') @($hostConstants)
        Assert-True ($state.Code -eq 0 -and $state.Out -match 'PASS:') "Win32 host FP state regression: $($state.Out)$($state.Err)"
        $script:checks++
        $hostSources = @($hostConstants)
        foreach ($name in @('scale', 'integer_math', 'functions_for', 'vector_math', 'layout_records', 'constant_tables',
            'extended_numeric', 'extended_flow', 'sample_texture')) {
            $hostSources += Join-Path $root "examples\$name.pas"
        }
        foreach ($name in @('extended_numeric.pas', 'intrinsic_edges.pas', 'vector_edges.pas', 'syntax_group2.pas',
            'graphics_fragment.pasm', 'combined_texture.pasm')) {
            $hostSources += Join-Path $root "tests\fixtures\$name"
        }
        foreach ($source in $hostSources) {
            foreach ($mode in @('-O0', '-O1')) {
                $name = [IO.Path]::GetFileNameWithoutExtension($source) + $mode
                $native = Join-Path $win32 "$name-win64.spv"
                $other = Join-Path $win32 "$name-win32.spv"
                $run64 = Invoke-Tool $compiler @('compile', $source, '-o', $native, $mode)
                $run32 = Invoke-Tool (Join-Path $win32 'PasToSPIRV.exe') @('compile', $source, '-o', $other, $mode)
                Assert-True ($run64.Code -eq 0 -and $run32.Code -eq 0) "Host comparison failed to compile ${name}: $($run64.Err)$($run32.Err)"
                Assert-True ((Get-FileHash $native).Hash -eq (Get-FileHash $other).Hash) "Win32 and Win64 builds emit different SPIR-V for $name"
                Assert-True ((Get-FileHash ([IO.Path]::ChangeExtension($native, '.json'))).Hash -eq
                    (Get-FileHash ([IO.Path]::ChangeExtension($other, '.json'))).Hash) "Win32 and Win64 builds emit different reflection for $name"
            }
        }
        $script:checks++
    }
}
else { Write-Warning 'Host floating-point state and other-host builds were explicitly skipped (-SkipDelphiTests).' }
