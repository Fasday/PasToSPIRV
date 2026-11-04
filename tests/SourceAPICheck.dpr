program SourceAPICheck;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  PTS.Compiler in '..\source\PTS.Compiler.pas',
  PTS.Diagnostics in '..\source\PTS.Diagnostics.pas',
  PTS.Source in '..\source\PTS.Source.pas',
  PTS.SourceLoader in '..\source\PTS.SourceLoader.pas',
  PTS.ConstEval in '..\source\PTS.ConstEval.pas',
  PTS.FloatEnvironment in '..\source\PTS.FloatEnvironment.pas',
  PTS.Names in '..\source\PTS.Names.pas',
  PTS.FileSafety in '..\source\PTS.FileSafety.pas',
  PTS.Analysis in '..\source\PTS.Analysis.pas',
  PTS.FlowAnalysis in '..\source\PTS.FlowAnalysis.pas',
  PTS.Profile in '..\source\PTS.Profile.pas',
  PTS.References in '..\source\PTS.References.pas',
  PTS.FloatLiteral in '..\source\PTS.FloatLiteral.pas',
  PTS.Features in '..\source\PTS.Features.pas',
  PTS.IR in '..\source\PTS.IR.pas',
  PTS.Types in '..\source\PTS.Types.pas',
  PTS.Layout in '..\source\PTS.Layout.pas',
  PTS.Reflection in '..\source\PTS.Reflection.pas',
  PTS.Bindings in '..\source\PTS.Bindings.pas',
  PTS.Lexer in '..\source\PTS.Lexer.pas',
  PTS.Parser in '..\source\PTS.Parser.pas',
  PTS.SPIRV in '..\source\PTS.SPIRV.pas';

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then raise EInvalidOpException.Create(AMessage);
end;

procedure CheckStringMode(const ASource: string);
var
  Rejected: Boolean;
begin
  Rejected := False;
  try
    TShaderCompiler.Compile(ASource);
  except
    on E: EShaderError do
    begin
      Rejected := Pos('file compilation', E.Message) <> 0;
      Check(E.Position.FileName = '', 'Unexpected file I/O origin in string compilation');
    end;
  end;
  Check(Rejected, 'String API must not resolve filesystem dependencies');
end;

var
  Compilation: TCompilationResult;
  Metadata: TJSONObject;
  HadOutput: Boolean;
  ShaderPath, OriginalOutput, ErrorPath: string;
begin
  try
    if ParamCount <> 3 then raise EArgumentException.Create('Expected shader, search directory and included-error shader');
    Compilation := TShaderCompiler.Compile('procedure Main; begin end;');
    Check(Length(Compilation.SPIRV) > 20, 'String API did not compile');
    CheckStringMode('{$I ''missing.inc''}' + #10 + 'procedure Main; begin end;');
    CheckStringMode('uses Missing; procedure Main; begin end;');
    ShaderPath := TPath.GetFullPath(ParamStr(1));
    OriginalOutput := ChangeFileExt(ShaderPath, '.spv');
    HadOutput := TFile.Exists(OriginalOutput);
    Compilation := TShaderCompiler.CompileFile(ShaderPath, TArray<string>.Create(ParamStr(2)), 'APIBindings');
    Check(Length(Compilation.SPIRV) > 20, 'File API did not compile');
    Check(Pos('unit APIBindings;', Compilation.Bindings) <> 0, 'Bindings option did not reach the file API');
    Check(TFile.Exists(OriginalOutput) = HadOutput, 'File API wrote an output file');
    Metadata := TJSONObject.ParseJSONValue(Compilation.Reflection) as TJSONObject;
    try
      Check(Metadata.GetValue<TJSONArray>('sources').Count = 7, 'Dependency manifest size');
      Check(Metadata.GetValue<TJSONArray>('modules').Count = 3, 'Module de-duplication');
    finally
      Metadata.Free;
    end;
    ErrorPath := '';
    try
      TShaderCompiler.CompileFile(ParamStr(3));
    except
      on E: EShaderError do
      begin
        ErrorPath := TPath.GetFileName(E.Position.FileName);
        Check((E.Position.Line = 3) and (E.Position.Column = 3), 'Included source coordinates were lost');
      end;
    end;
    Check(SameText(ErrorPath, 'bad.inc'), 'Included source filename was lost');
    Writeln('PASS: pure string API, file API, dependency manifest and mapped diagnostics.');
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.Message);
      ExitCode := 1;
    end;
  end;
end.
