unit PTS.Compiler;

{$BOOLEVAL OFF}

interface

uses
  System.SysUtils,
  PTS.Source;

const
  CompilerVersion = '1.4.1';

type
  TCompilationResult = record
    SPIRV: TBytes;
    Reflection: string;
    Bindings: string;
  end;

  TShaderCompiler = class
  public
    class function Compile(const ASource: string; const ABindingsUnit: string = ''; AOptimize: Boolean = False;
      const AEntryPointName: string = 'Main'): TCompilationResult; static;
    class function CompileText(const ASource: string; const AFileName: string = 'shader.pas';
      const ADependencies: TArray<TSourceText> = nil; const ASearchDirectories: TArray<string> = nil;
      const ABindingsUnit: string = ''; AOptimize: Boolean = False;
      const AEntryPointName: string = 'Main'): TCompilationResult; static;
    class function CompileFile(const AFileName: string; const AIncludeDirectories: TArray<string> = nil;
      const ABindingsUnit: string = ''; AOptimize: Boolean = False;
      const AEntryPointName: string = 'Main'): TCompilationResult; static;
    class function CompileResolved(ASources: TSourceProgram; const ABindingsUnit: string = ''; AOptimize: Boolean = False;
      const AEntryPointName: string = 'Main'): TCompilationResult; static;
  end;

implementation

uses
  PTS.IR,
  PTS.Parser,
  PTS.SPIRV,
  PTS.Reflection,
  PTS.Bindings,
  PTS.ConstEval,
  PTS.Names,
  PTS.FloatEnvironment,
  PTS.SourceLoader;

function FinishCompilation(Module: TShaderModule; const ABindingsUnit: string;
  ASources: TSourceProgram; AOptimize: Boolean; const AEntryPointName: string): TCompilationResult;
var
  Writer: TSPIRVWriter;
begin
  Result.Bindings := '';
  try
    Module.EntryPointName := AEntryPointName;
    if AOptimize then OptimizeConstants(Module);
    Writer := TSPIRVWriter.Create(Module);
    try
      Result.SPIRV := Writer.Generate;
    finally
      Writer.Free;
    end;
    Result.Reflection := BuildReflection(Module, CompilerVersion, ASources, AOptimize);
    if ABindingsUnit <> '' then Result.Bindings := GenerateBindings(Module, ABindingsUnit);
  finally
    Module.Free;
  end;
end;

function CompileUsingParser(AParser: TParser; const ABindingsUnit: string;
  ASources: TSourceProgram; AOptimize: Boolean; const AEntryPointName: string): TCompilationResult;
var
  State: TCompilerFloatState;
  Module: TShaderModule;
begin
  State := EnterCompilerFloatEnvironment;
  try
    try
      Module := AParser.Parse;
    finally
      AParser.Free;
    end;
    Result := FinishCompilation(Module, ABindingsUnit, ASources, AOptimize, AEntryPointName);
  finally
    LeaveCompilerFloatEnvironment(State);
  end;
end;

class function TShaderCompiler.Compile(const ASource: string; const ABindingsUnit: string; AOptimize: Boolean;
  const AEntryPointName: string): TCompilationResult;
begin
  ValidateEntryPointName(AEntryPointName);
  Result := CompileUsingParser(TParser.Create(ASource), ABindingsUnit, nil, AOptimize, AEntryPointName);
end;

class function TShaderCompiler.CompileFile(const AFileName: string;
  const AIncludeDirectories: TArray<string>; const ABindingsUnit: string; AOptimize: Boolean;
  const AEntryPointName: string): TCompilationResult;
var
  Sources: TSourceProgram;
begin
  ValidateEntryPointName(AEntryPointName);
  Sources := LoadSourceProgram(AFileName, AIncludeDirectories);
  try
    Result := CompileResolved(Sources, ABindingsUnit, AOptimize, AEntryPointName);
  finally
    Sources.Free;
  end;
end;

class function TShaderCompiler.CompileText(const ASource, AFileName: string;
  const ADependencies: TArray<TSourceText>; const ASearchDirectories: TArray<string>;
  const ABindingsUnit: string; AOptimize: Boolean; const AEntryPointName: string): TCompilationResult;
var
  Sources: TSourceProgram;
begin
  ValidateEntryPointName(AEntryPointName);
  Sources := LoadSourceText(ASource, AFileName, ADependencies, ASearchDirectories);
  try
    Result := CompileResolved(Sources, ABindingsUnit, AOptimize, AEntryPointName);
  finally
    Sources.Free;
  end;
end;

class function TShaderCompiler.CompileResolved(ASources: TSourceProgram; const ABindingsUnit: string; AOptimize: Boolean;
  const AEntryPointName: string): TCompilationResult;
begin
  ValidateEntryPointName(AEntryPointName);
  if (ASources = nil) or (ASources.Root = nil) then
    raise EArgumentException.Create('CompileResolved requires a source program with an entry document');
  Result := CompileUsingParser(TParser.Create(ASources), ABindingsUnit, ASources, AOptimize, AEntryPointName);
end;

end.
