# Loaded by scripts/test.ps1; compiler and validator are test-only tools.
foreach ($name in @('graphics_vertex', 'graphics_fragment', 'combined_texture',
    'combined_sample', 'graphics_vector_math', 'graphics_interface_vertex',
    'graphics_interface_fragment', 'combined_fetch')) {
    $source = [IO.File]::ReadAllText((Join-Path $root "tests\fixtures\$name.pasm"))
    Test-Success $name $source
}
Test-Success 'mixed_vector_constructor' 'procedure Main; var A: Single4; begin A := Single4(Single2(1,2),Single2(3,4)); end;' 'OpCompositeConstruct'
Test-Success 'vector_arithmetic_shift' 'procedure Main; var A: Integer3; begin A := ArithmeticShiftRight(Integer3(-16,-8,-4),2); end;' 'OpShiftRightArithmetic'

foreach ($profile in @('Vulkan11', 'Vulkan12')) {
    $name = "graphics_interlock_$profile"
    $source = [IO.File]::ReadAllText((Join-Path $root 'tests\fixtures\graphics_interlock.pasm')).Replace('Vulkan11', $profile)
    $input = Join-Path $cases "$name.pasm"
    $output = Join-Path $cases "$name.spv"
    [IO.File]::WriteAllText($input, $source, $utf8)
    $result = Invoke-Tool $compiler @('compile', $input, '-o', $output)
    Assert-True ($result.Code -eq 0) "$name failed: $($result.Err)"
    $envName = 'vulkan1.1'
    if ($profile -eq 'Vulkan12') { $envName = 'vulkan1.2' }
    $validation = Invoke-Tool $SpirvVal @('--target-env', $envName, $output)
    Assert-True ($validation.Code -eq 0) "$name validation failed: $($validation.Err)"
    $json = Get-Content ([IO.Path]::ChangeExtension($output, '.json')) -Raw | ConvertFrom-Json
    Assert-True ($json.stage -eq 'fragment' -and $json.pixel_interlock_ordered) 'Interlock stage reflection'
    Assert-True ($json.required_features -contains 'fragmentShaderPixelInterlock') 'Missing interlock feature'
    Assert-True ($json.required_device_extensions -contains 'VK_EXT_fragment_shader_interlock') 'Missing interlock device extension'
    Assert-True ($json.images[0].coherent) 'Missing coherent image metadata'
    $assembly = Invoke-Tool $SpirvDis @($output)
    Assert-True ($assembly.Out -match 'OpBeginInvocationInterlockEXT' -and $assembly.Out -match 'OpEndInvocationInterlockEXT') 'Missing interlock instructions'
    $script:checks++
}

$vertex = Get-Content (Join-Path $cases 'graphics_vertex.json') -Raw | ConvertFrom-Json
Assert-True ($vertex.stage -eq 'vertex' -and $vertex.inputs.Count -eq 2 -and $vertex.outputs.Count -eq 2) 'Vertex interface reflection'
Assert-True ($vertex.outputs[1].interpolation -eq 'noperspective') 'Vertex interpolation reflection'
$fragment = Get-Content (Join-Path $cases 'graphics_fragment.json') -Raw | ConvertFrom-Json
Assert-True ($fragment.stage -eq 'fragment' -and $fragment.outputs[1].builtin -eq 'FragDepth') 'Fragment depth reflection'
$combined = Get-Content (Join-Path $cases 'combined_texture.json') -Raw | ConvertFrom-Json
Assert-True ($combined.textures[0].descriptor_type -eq 'combined_image_sampler') 'Combined texture descriptor reflection'
Assert-True ($combined.textures[1].value_type -eq 'Cardinal4') 'Unsigned combined texture reflection'
$script:checks++

foreach ($case in @(
    @('graphics_stage_conflict', '[Vertex,Fragment] procedure Main; begin end;', 'conflicting shader stages'),
    @('graphics_compute_interface', 'var [Input,Location(0)] A: Single; procedure Main; begin end;', 'require Vertex or Fragment'),
    @('graphics_local_size', 'var [Output,Builtin(Position)] P: Single4; [Vertex,LocalSize(1,1,1)] procedure Main; begin P := Single4(0); end;', 'cannot use LocalSize'),
    @('graphics_no_position', '[Vertex] procedure Main; begin end;', 'require a Position'),
    @('graphics_wrong_builtin_stage', 'var [Output,Builtin(Position)] P: Single4; [Fragment] procedure Main; begin P := Single4(0); end;', 'vertex outputs'),
    @('graphics_wrong_builtin_type', 'var [Output,Builtin(FragDepth)] D: Cardinal; [Fragment] procedure Main; begin D := 0; end;', 'Incorrect graphics built-in type'),
    @('graphics_input_write', 'var [Input,Location(0)] A: Single4; [Fragment] procedure Main; begin A := Single4(0); end;', 'inputs are read-only'),
    @('graphics_output_read', 'var [Output,Location(0)] A: Single4; [Fragment] procedure Main; begin A := A; end;', 'outputs are write-only'),
    @('graphics_output_partial', 'var [Output,Location(0)] A: Single4; [Fragment] procedure Main; begin A.X := 0; end;', 'whole values'),
    @('graphics_output_helper', 'var [Output,Location(0)] A: Single4; procedure SetColor; begin A := Single4(0); end; [Fragment] procedure Main; begin SetColor; end;', 'assigned in Main'),
    @('graphics_output_missing_path', 'var [Input,Builtin(FragCoord)] P: Single4; [Output,Location(0)] A: Single4; [Fragment] procedure Main; begin if P.X > 0 then A := Single4(0); end;', 'may be unwritten'),
    @('graphics_location_duplicate', 'var [Input,Location(0)] A: Single; [Input,Location(0)] B: Single; [Fragment] procedure Main; begin end;', 'Duplicate stage interface'),
    @('graphics_integer_varying', 'var [Input,Location(0)] A: Integer; [Fragment] procedure Main; begin end;', 'require Flat'),
    @('graphics_derivative_compute', 'procedure Main; var A: Single; begin A := DdxFine(1.0); end;', 'require a fragment'),
    @('graphics_discard_compute', 'procedure Main; begin Discard; end;', 'requires a fragment'),
    @('graphics_interlock_missing_block', '[Fragment,PixelInterlockOrdered] procedure Main; begin end;', 'requires exactly one Interlock'),
    @('graphics_interlock_missing_attribute', '[Fragment] procedure Main; begin Interlock begin end; end;', 'requires exactly one Interlock'),
    @('graphics_interlock_conditional', '[Fragment,PixelInterlockOrdered] procedure Main; begin if True then Interlock begin end; end;', 'outside control constructs'),
    @('graphics_interlock_return', '[Fragment,PixelInterlockOrdered] procedure Main; begin Interlock begin Exit; end; end;', 'cannot terminate'),
    @('graphics_interlock_discard_call', 'procedure Reject; begin Discard; end; [Fragment,PixelInterlockOrdered] procedure Main; begin Interlock begin Reject; end; end;', 'may Discard'),
    @('graphics_fetch_coordinates', 'var [Binding(0,0)] T: CombinedTexture2D; procedure Main; var C: Single4; begin C := TexelFetch(T, Single2(0), 0); end;', 'coordinates must be'),
    @('graphics_integer_sampling', 'var [Binding(0,0)] T: CombinedTexture2DUInt; procedure Main; var C: Single4; begin C := SampleLevel(T, Single2(0), 0.0); end;', 'floating-point texture')
)) {
    Test-Failure $case[0] $case[1] $case[2]
}
