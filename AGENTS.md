# PasToSPIRV

Standalone compiler written in Delphi: a documented Pascal shader subset to
SPIR-V for Vulkan. This is not a Delphi-to-GPU application converter.

## Project boundaries

- Compiler implementation belongs in `source/` and must remain Delphi-only.
- Generate binary SPIR-V directly. Do not route compilation through GLSL,
  glslang, DXC or another external compiler.
- Vulkan SDK tools are development/test dependencies, not runtime dependencies
  of the compiler. The optional Python Vulkan test uses the standard library.
- Default target: SPIR-V 1.0 / Vulkan 1.0, compute Main. Explicit Vulkan12 uses
  SPIR-V 1.3 / Vulkan 1.2; reflect required device features, never upgrade silently.
- Version 1.x is a bounded compute language, not full Delphi/GLSL. Keep
  `docs/compatibility.md` and `docs/gpu.md` in sync with accepted constructs.
- Keep documentation and examples independent of any particular consuming
  application. This is a standalone compiler repository.
- Keep parsing/type checking in the frontend and emission in the backend.
  Unsupported syntax and attributes must fail explicitly, not be ignored.
- GPU integer operations have explicit width-specific modular semantics (32-bit
  by default; optional 8/16/64-bit scalars). Do not silently
  inherit host Delphi arithmetic, floating-point or record layout behavior.
- Change language behavior together with `docs/language.md` and regression
  tests. Do not promise full Delphi compatibility or bit-identical CPU/GPU
  floating-point results.
- External resources use the tested std430 calculator in `PTS.Layout`.
  Never infer GPU offsets/array strides from host Delphi records. Reflection
  schema v2 and optional generated packed Delphi bindings must agree with it.
- Boolean is forbidden recursively in external resources. Local aggregates
  require whole-value initialization (for example `Default(Type)`) before writes
  to their members. Preserve type identity, value copies and genuine local var/out
  aliases (including overlapping fields); never substitute copy-in/copy-out.
- `Compile(string)` must remain free of source filesystem resolution.
  File loading belongs to `CompileFile`/`PTS.SourceLoader`, with original-file
  positions, explicit search directories, budgets, cycle/ambiguity checks.
- Modules are declaration-only `.pasm`; imports are once-only and dependency-visible.
  Includes are textual, own-line `$I/$INCLUDE` only. The only other directive is
  the local `$B`/`$BOOLEVAL` switch (Boolean and/or short-circuit by default, as in
  Delphi). Do not silently enable other Delphi directives, full units, ambient
  working-directory search or macros.
- Dependency manifests must not embed absolute build paths. Shared CPU/GPU
  equivalence must be tested against the actual Delphi-compiled `.inc` sources,
  not asserted from identical text or a Python rewrite alone.
- Exports are keyed by module/name; reject ambiguous unqualified names, not
  legitimate same-named exports in different modules. Intrinsics stay reserved.
- Nested routines keep captured variables in Private storage; this is exact only
  because the call graph is acyclic (keep `CheckCallGraph`). Definite assignment at
  calls uses their `CaptureReads/CaptureWrites` summaries. Enumerations and sets are
  32-bit words without external layout; keep them out of resources and reflection.
- Atomics are relaxed 32-bit RMW on ReadWrite buffers/shared scalars. Workgroup
  Barrier is Main-only and outside all if/while/for constructs. Never advertise
  this syntactic restriction as a proof of race freedom or termination.
- Images/samplers are opaque descriptors, never std430 byte values. Float
  texture sampling uses explicit LOD. Check image formats/capabilities on the host.
- O1 may fold only defined integral/Boolean constants. Do not reassociate or
  fold floating-point operations or remove atomic/resource side effects.
- Batch cache must re-resolve dependencies and check artifact hashes before hits;
  source snapshots must be the same ones passed to CompileResolved.
- A consumed module qualifier must never fall back to locals/resources/built-ins
  or anonymous type syntax. Missing exports are errors.
- Win64 compiler entry points isolate and restore MXCSR; do not inherit caller
  rounding/FTZ/DAZ/status. Shifts mask by width-1; preserve explicitly 32-bit host
  operations for existing types, and distinguish logical shr from arithmetic shift.
- Windows output safety must compare canonical destinations/file identities,
  not only lexical paths; cover hard links and directory junctions in regressions.
  Not-yet-existing outputs compare by existing-ancestor identity plus folded tail.
- Definite assignment must stay loop-aware (`PTS.Analysis`); include expansion
  must stay memoised. Only untyped literals/constants adapt between Integer and
  Cardinal; typed constants and casts keep their type.
- Real literals are rounded once from exact decimal (`PTS.FloatLiteral`), including
  binary64 d-literals; StrictFloat is not a guarantee of bit-exact native division.
  Keep `tests/fixtures/float_literals.txt` generated by the independent oracle.

## Validation

From the repository root in PowerShell:

```powershell
.\scripts\build.ps1
.\scripts\test.ps1 -SkipBuild
python .\tests\vulkan_smoke.py --require-shared-cpu
python .\tests\vulkan_extended.py
python .\tests\audit_typed_trees.py --count 300 --depth 6 --rounds 2
python .\tests\audit_flow_runtime.py --programs 40
python .\tests\audit_numeric_gpu.py --count 256
```

The Vulkan smoke command requires a fresh `SharedSourceCheck.exe` (built by test.ps1).
The numeric audit additionally requires `spirv-val`. Both GPU commands require
Python, the Vulkan loader and a compute device with
host-visible, host-coherent memory. It is optional on machines without Vulkan;
report explicitly if it was not run. `scripts/test.ps1` requires `spirv-val`
and `spirv-dis`, validating default fixtures for Vulkan 1.0 and Vulkan12 fixtures
for Vulkan 1.2. Extended GPU tests require the reflected optional features.

Use two-space indentation in Delphi, four spaces in PowerShell/Python.
Generated files belong under `build/`. Do not add a license or copyright
owner on the user's behalf.
