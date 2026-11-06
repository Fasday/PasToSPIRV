# Explicit graphics stages

Compute remains the default. `[Vertex]` and `[Fragment]` select native SPIR-V
execution models without routing source through GLSL or an external compiler.
They can be combined with the existing Vulkan11/Vulkan12 and StrictFloat
profiles; the source entry procedure and configurable external name are unchanged.

```pascal
var
  [Input, Location(0)] InPosition: Single3;
  [Input, Location(1)] InColor: Single4;
  [Output, Builtin(Position)] ClipPosition: Single4;
  [Output, Location(0), NoPerspective] VertexColor: Single4;

[Vertex]
procedure Main;
begin
  ClipPosition := Single4(InPosition, 1.0);
  VertexColor := InColor;
end;
```

## Interfaces

- Exactly one `Input`/`Output` and one `Location(N)`/`Builtin(Name)` per interface
  variable. Locations are 0..31; duplicate locations within a direction fail.
- Locations hold 32-bit Integer/Cardinal/Single scalars or vectors. No records,
  arrays, Boolean or small/64-bit interface types in this bounded implementation.
- `Flat` and `NoPerspective` belong on vertex outputs or fragment inputs.
  Integer varyings require Flat. Smooth perspective interpolation is the default.
- Built-ins: vertex outputs Position (Single4), PointSize (Single); vertex inputs
  VertexIndex/InstanceIndex (Integer); fragment inputs FragCoord (Single4),
  FrontFacing (Boolean); fragment output FragDepth (Single).
- Vertex shaders require Position. Fragment uses OriginUpperLeft; a FragDepth
  output also emits DepthReplacing. No implicit early-fragment-tests mode.
- Inputs are read-only. Outputs are write-only, assigned as whole values in Main.
  Every declared output must be assigned on every reachable return/fallthrough;
  Discard paths have no output obligation. Loops conservatively cannot establish
  an output after the loop. Use local intermediates for partial updates.
- Compute invocation built-ins, Shared, workgroup Barrier and LocalSize are
  rejected in graphics stages. Other shader stages are not supported.

Reflection v2 reports the actual stage/profile, input/output locations, built-ins
and interpolation. Graphics `local_size` is empty. Host bindings generation does
not misclassify stage interfaces as push constants. Pipeline vertex formats,
fragment attachments and stage linkage remain the host's responsibility.

## Operations and textures

- `Discard;` terminates the fragment invocation, including inside helpers.
- `DdxFine`/`DdyFine` accept Single scalars/vectors in fragment shaders only.
  They request DerivativeControl. The author must still ensure derivative
  operations execute with valid quad participation; this is not a uniformity proof.
- `RoundFloat`/`FloorFloat` keep the Single scalar/vector type, unlike Delphi-style
  Round/Floor integer results. RoundFloat follows GLSL.std.450 Round (halfway
  direction is not a cross-device bit-exact guarantee).
- Vector constructors can combine vectors/scalars whose component counts sum
  to the result width, evaluating arguments once in source order.
- `ArithmeticShiftRight` also accepts Integer vectors with 32-bit scalar/vector
  counts. Counts retain the existing width-masked semantics.
- `CombinedTexture2D` and `CombinedTexture2DUInt` use combined-image-sampler
  descriptors and return Single4/Cardinal4 respectively from
  `TexelFetch(Texture, Integer2OrCardinal2, IntegerLod)`.
- `TextureSize(Texture, IntegerLod)` returns Integer2. `SampleLevel` additionally
  accepts `(CombinedFloatTexture, Single2UV, SingleLod)`; existing separate
  Texture2D/Sampler syntax is unchanged. No implicit-LOD or filtered integer sampling.

## Ordered pixel interlock

```pascal
var
  [Input, Builtin(FragCoord)] Pixel: Single4;
  [Binding(0,0), Coherent] Target: Image2D_RGBA8;

[Fragment, PixelInterlockOrdered, Vulkan11]
procedure Main;
begin
  Interlock begin
    var Value: Single4 := ImageLoad(Target, Integer2(Pixel.XY));
    ImageStore(Target, Integer2(Pixel.XY), Value);
  end;
end;
```

Exactly one Interlock block at Main scope, outside conditional/loop constructs.
The block cannot return, Discard or call a function that may Discard. This
structural restriction guarantees matched begin/end instructions, not general
race freedom. Fragment shader pixel interlock and fragmentStoresAndAtomics are
reflected as required features, with `VK_EXT_fragment_shader_interlock` as a
required device extension even on Vulkan 1.2. The host must enable them and
provide the appropriate storage-image format and synchronization.

No precision weakening or emulation of absent device features is implied.

## Validation

`scripts/test.ps1` validates positive and negative graphics fixtures and reflects
their actual interface/device contracts. `python tests/vulkan_graphics.py` runs
native vertex/fragment pipelines, fine derivatives, helper Discard, mixed-vector
construction and combined float/unsigned texture fetch on the GPU at O0/O1.
The latter uses only Python's standard library and the Vulkan loader; it is test
infrastructure, not an application runtime or a replacement shader compiler.
