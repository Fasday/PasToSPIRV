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
beside its importing source, then in the component's explicitly supplied
`SearchDirectories`. Includes use the same resolver. Absolute names and paths
escaping the namespace are rejected; ambiguous or missing dependencies are
errors. The compiler never consults the current directory or reads a dependency
from disk in this mode. Resource streams can be decoded as UTF-8 by the caller
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
