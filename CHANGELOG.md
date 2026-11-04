# Changelog

## 1.3.0 — Delphi syntax, group 2

- Enumerations `(A, B = 5, C)` with `TEnum.Value`, comparisons, Ord/Succ/Pred/Low/High,
  Inc/Dec, case, for and explicit casts; `set of TEnum` (ordinals 0..31) as 32-bit masks
  with `+ - * = <> <= >=`, Include/Exclude and constructors `[A, B..C]`; `in` / `not in`,
  including integer constructors `I in [1, 3..5]`. Enumerations and sets are rejected
  in external resources.
- Delphi 13 if expressions: only the selected branch runs (OpSelect for pure scalar/vector
  branches, otherwise branch + OpPhi); literals adapt branch-wise to the target type.
- Swizzles `.XY`, `.ZYX`, `.RGBA` (read; write of distinct components per component),
  multi-dimensional arrays `array[0..A, 0..B]` and `M[I, J]`, record/vector typed constants,
  several type sections, Low/High of integer/enumeration variables.
- `forward` declarations (full or short definition), `overload` with per-argument cost
  resolution, nested routines with captured variables in Private storage, call summaries
  for definite assignment and an acyclic call-graph check.
- New reserved names: Include, Exclude. Reflection `language_version` is 1.3.

## 1.2.0 — Delphi syntax, group 1

- Boolean `and`/`or` short-circuit by default, as Delphi `{$B-}`; `{$B+}`/`{$BOOLEVAL ON}`
  (and `(*$...*)` forms) select complete evaluation as a local switch. Behavior change:
  side effects in a skipped right operand no longer run. Pure right operands still use
  OpLogicalAnd/Or; others use a structured branch with OpPhi.
- `A, B: T` in local var sections and record fields; local `const` sections; inline
  `var X: T [:= E]`, `var X := E` and `const K = E` with block scope; `for var I := ...`.
- `Inc/Dec` (single address evaluation), `Low/High/Length/SizeOf` (std430 size,
  `Length(Buffer)` = OpArrayLength), `Ord`, `Odd`, `Sqr`, `Succ`, `Pred`.
- Case range labels `Low..High`; calls without `()` for parameterless routines;
  `F := Value` (also `F.Field`, `F[I]`) inside F assigns the result.
- New reserved names: Ord, Sqr, Odd, Succ, Pred, Inc, Dec, Low, High, Length, SizeOf.

## 1.1.2 — second audit of the extended language

- Emit integer negation and `Abs` as `0 - X` instead of `OpSNegate`: the tested AMD
  driver optimized SNegate as no-wrap, so `(-Low(Integer)) div N`, `(-A) < 0` and
  `Abs(Low(Integer))` produced wrong results on the GPU (also in the Vulkan 1.0 profile).
- Reject implicit widening of an untyped constant expression that wrapped in its
  own type (`Int64 := 100000 * 100000`, `1 shl 40`); same-type 1.0 semantics kept.
  Literals converted inside expressions stay untyped.
- Restore bindings unit names Byte/Word/Int64/UInt64/Double (System-qualified host types).
- New GPU audits: random typed trees (const/O0/O1/buffer vs exact model) and random
  control-flow programs executed against an independent interpreter. See docs/audit-1.1.2.md.

## 1.1.1 — extended-language audit

- Fix six unsigned-width-to-signed casts that emitted invalid OpUConvert.
- Preserve explicit cast types for unary/binary constants and reject typed
  unsigned minimum negation; make wide untyped operand inference order-independent.
- Correct late value-argument initialization before var calls; preserve runtime
  floating indices in reference specializations.
- Enforce portable SPIR-V switch/parameter limits, including expanded reference
  signatures, with instruction word-count protection and linear case accumulation.
- Correct Floor/Ceil boundary values in the Delphi test reference. Add full cast
  validation, independent explicit-state flow and Fraction/integer GPU audits.
- Record native Double division differences separately, without claiming that
  StrictFloat supplies universally correctly-rounded division. See docs/audit-1.1.1.md.

## 1.1.0 — extended compute language

- Explicit `[Vulkan12]` profile: SPIR-V 1.3 / Vulkan 1.2, native Byte/Word storage,
  Int64/UInt64/Double scalars, width-specific modular arithmetic and exact decimal
  binary64 d-literals. Default SPIR-V 1.0 / Vulkan 1.0 is unchanged.
- Optional `[StrictFloat]` modes, reflected required device features, bitcasts,
  defined Round/Trunc/Floor/Ceil conversions, RoundEven, IsNan/IsInfinite, Ldexp,
  FindMSB/LSB and explicit arithmetic right shift. Native float division is not
  advertised as universally CPU bit-exact.
- Helper procedures, const value parameters, true local var/out aliases through
  memory-root/path specialization (no copy-in/copy-out or VariablePointers device
  requirement), resource/built-in access in root helpers and discarded calls.
- Exit/Break/Continue/repeat/case with CFG-based definite assignment for new flow;
  typed constant array tables with dynamic indexing. Existing loop-aware checks,
  aggregate identity/initialization and Main-only atomics/barriers are retained.
- `[Aliased]` storage-buffer views, mixed-width std430 reflection/Delphi bindings,
  Vulkan 1.2 O0/O1 fixtures and real GPU comparisons against Delphi Win64.
- No consuming renderer/application was migrated.

## Unreleased — examples

- `examples/sketch`: SketchBench, a Delphi pencil-sketch application and
  benchmark (CPU 1 thread / all cores vs PasToSPIRV shader on Vulkan) with
  WIC image I/O, QueryPerformanceCounter and Vulkan timestamp timing, and a
  bit-exact CPU/GPU comparison through shared integer math.
- `examples/sketch`: SketchVCL and SketchFMX GUI demos on a shared engine
  (open/synthetic image, radius, method, run, benchmark, save, `--selftest`).
  The FMX demo also times FireMonkey's built-in `TFilterPencilStroke`.
- Both GUI demos create color thumbnails with aspect fit, no upscaling, preset
  bounds, PNG saving and benchmarks. Separable integer area filtering (including
  fractional coverage and premultiplied alpha) is bit-identical on Delphi CPU
  and Vulkan. FMX also times its stock `TBitmap.CreateThumbnail` path. Independent
  Int64 reference, edge-case tests and real GPU comparisons cover the resize path.
- `scripts/build.ps1 -Resources <file.rc>` compiles resource scripts with
  Delphi's `cgrc` into `build\res` before building a project.
- `scripts/build.ps1 -OutputDirectory` isolates test/demo builds from running
  applications; GUI tests build under `build\tests\sketch-gui`.

## 1.0.2 — second independent audit

- Loop-aware definite assignment (no hang from re-reading a stale for counter).
- Include expansion memoised; dependency edges recorded once per directive.
- Shared arrays with externally laid-out types now emit valid Workgroup types.
- Typed constants/casts keep their type; Clamp requires one common type.
- Constant contexts reject variable/resource reads instead of crashing.
- Constant negative/out-of-range indices rejected before code generation.
- Correctly rounded real literals; indexed name lookup; compiler limits.
- Output aliasing via UNC/Unicode case, empty CLI arguments, duplicate JSON
  keys, late bindings-name validation and ADS outputs fixed.
- Reserved module names; RTL-qualified generated bindings; identifier limit 127.
- Source-order evaluation of selector indices is now specified.

## 1.0.1 — correctness audit

- Fixed masked large-count integer left shifts in constant evaluation/O1;
  verified against an independent arithmetic oracle and actual O0/O1/const GPU results.
- Qualified missing exports can no longer fall back to locals, shader resources,
  invocation built-ins, Boolean literals or anonymous record/array syntax.
- Shared arrays are now covered by the Main-only resource rule; pure helper
  functions may consume value copies but cannot capture hidden shared state.
- Win64 compilation pins nearest rounding, disables FTZ/DAZ and masks exceptions
  for parsing/evaluation, restoring the caller's full MXCSR on success/error.
- Windows CLI/batch output preflight checks physical file identity and canonical
  destinations, rejecting hard-link/junction aliases of sources and outputs.
- Added audit regressions and deterministic GPU arithmetic differential tests.

## 1.0.0 — bounded compute-vulkan1.0 profile

- Typed scalar constants, constant expressions in bounds/attributes, qualified
  module function/type/constant names and ambiguity diagnostics.
- 32-bit atomic add/exchange/compare-exchange with explicit old-value semantics.
- Scalar shared arrays, local/workgroup built-ins, conservative unconditional
  workgroup barriers and buffer/image memory barriers.
- R32UInt/R32Int/RGBA32Float/RGBA8 storage images, typed load/store/size.
- Float Texture2D + separate Sampler, explicit LOD sampling; nearest/linear tested.
- Project format 1 batch builds with source/output collision preflight and
  snapshot-based, artifact-hash-verified cache.
- Optional O1: defined integral/Boolean constant folding only, no floating-point
  reassociation or removal of GPU side effects. Wall-clock CLI benchmark harness.
- Reflection format 2 retained with additive resource/profile/optimization fields.
- Compatibility contract, migration notes, actual Vulkan and Delphi CPU/ABI/API tests.

This is not full Delphi/GLSL, not a Vulkan runtime, and not a claim of validation
on GPU vendors/targets unavailable in the development environment.

## 0.5
Mapped includes, declaration modules, deterministic dependency resolution,
source fingerprints, actual common Delphi/PasToSPIRV .inc examples.

## 0.4
std430 layout calculator, records/static arrays, Default(Type), reflection v2,
generated packed Delphi bindings and independently checked ABI.

## 0.3
Numeric vectors and basic math intrinsics.

## 0.2
Value functions and counted loops.

## 0.1
Direct Delphi frontend → typed IR → SPIR-V compute MVP.
