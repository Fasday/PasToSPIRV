# Runtime compilation

`PTS.Component.TShaderCompilerComponent` is a nonvisual Delphi component. It
generates SPIR-V directly from text, with no external compiler, Vulkan loader,
GUI framework or temporary source files. The same compiler units can be linked
into a desktop or mobile application.

```pascal
uses PTS.Component, PTS.Compiler, PTS.Source;

var Compiler := TShaderCompilerComponent.Create(nil);
try
  Compiler.SourceName := 'Main.pas';
  Compiler.EntryPointName := 'main'; // Optional; the default is Main.
  Compiler.Optimize := True;
  var Output := Compiler.Compile(ShaderText, [
    TSourceText.Create('Math.pasm', MathModuleText)]);
  // Output.SPIRV contains bytes; Reflection and optional Bindings contain text.
finally
  Compiler.Free;
end;
```

`SourceName` and dependency names are relative names in a private virtual
namespace, not filesystem paths. A module `uses Math;` resolves `Math.pasm`
beside its importing source and in the component's explicitly supplied
`SearchDirectories`. Includes use the same resolver. Absolute names are
rejected. A directory in which the name would leave the namespace (`..`) is
not searched, just as file mode skips a directory that lacks the file; such a
name is an error only when no directory resolves it. Ambiguous or missing
dependencies are errors. The compiler never consults the current directory or
reads a dependency from disk in this mode. Resource streams can be decoded as UTF-8 by the caller
and supplied in exactly the same way as any other text.

All supplied texts are immutable inputs to one compilation. Module de-duplication,
cycle checks, source/expansion budgets, original include locations and reflection
dependency hashes use the same loader as file compilation. Errors remain
`EShaderError`, including the logical source name, line and column. Each call
owns its parser and result; use a separately owned component for each compiling
thread and do not mutate its properties during compilation.

For code that does not need a component, the equivalent static entry point is
`TShaderCompiler.CompileText(Source, SourceName, Dependencies, SearchDirectories,
BindingsUnit, Optimize, EntryPointName)`. Existing `Compile(Source)` remains the pure,
self-contained string API; filesystem loading is still exclusively the job of
`CompileFile`.

The target device must still support every capability and feature reflected by
the compiled shader. Compiling at runtime does not emulate unavailable device
arithmetic or turn unsupported SPIR-V into a compatible module. Applications may
cache SPIR-V using the compiler version, all source/dependency hashes and the
complete compilation options, then pass it to their graphics API as usual.

## Host threads and floating-point state

A compilation pins the floating-point environment of the calling thread
(round to nearest, no flush-to-zero, exceptions masked) and restores the caller's
control and status bits exactly, also when it raises. On Windows x64 and x86 the
registers are accessed directly: the process-wide RTL defaults (`DefaultMXCSR`,
`Default8087CW`) and the state of other threads are never changed, so threads may
compile concurrently whatever their own rounding or exception settings are.
Constant folding gives the same SPIR-V on both hosts; on x86 it uses SSE2 scalar
operations instead of the x87 FPU.

Validated hosts: Win64 (the whole test suite) and Win32 (host-state checks and
byte-identical SPIR-V/reflection against Win64). The units also compile for
Linux64, macOS x64/ARM64, iOS and Android, but those hosts are not executed by
the tests. There the portable RTL interface pins rounding and exception masks
only, and it may update the RTL's process-wide defaults while a compilation runs.
