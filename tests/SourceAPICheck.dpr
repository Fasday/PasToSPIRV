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

procedure CheckEntryName(const AResult: TCompilationResult; const AExpected: string);
var
  Metadata: TJSONObject;
  Offset, I, Start: Integer;
  Header, WordValue: Cardinal;
  Actual: string;
begin
  Metadata := TJSONObject.ParseJSONValue(AResult.Reflection) as TJSONObject;
  try
    Check(Metadata.GetValue<string>('entry_point') = AExpected, 'API entry-point reflection mismatch');
  finally
    Metadata.Free;
  end;
  // Decode the NUL-terminated OpEntryPoint name directly from the binary.
  Offset := 20;
  Actual := '';
  while Offset < Length(AResult.SPIRV) do
  begin
    Move(AResult.SPIRV[Offset], Header, 4);
    if Header and $FFFF = 15 then
    begin
      Start := Offset + 12; // header, execution model, function ID
      I := Start;
      while (I < Length(AResult.SPIRV)) and (AResult.SPIRV[I] <> 0) do
      begin
        Actual := Actual + Char(AResult.SPIRV[I]);
        Inc(I);
      end;
      Break;
    end;
    WordValue := Header shr 16;
    Check(WordValue > 0, 'Invalid SPIR-V instruction length');
    Inc(Offset, Integer(WordValue) * 4);
  end;
  Check(Actual = AExpected, 'API binary entry-point mismatch');
end;

var
  Compilation: TCompilationResult;
  Metadata: TJSONObject;
  HadOutput: Boolean;
  ShaderPath, OriginalOutput, ErrorPath: string;
  Sources: TSourceProgram;
  BadName: string;
  Rejected: Boolean;
begin
  try
    if ParamCount <> 3 then raise EArgumentException.Create('Expected shader, search directory and included-error shader');
    Compilation := TShaderCompiler.Compile('procedure Main; begin end;');
    Check(Length(Compilation.SPIRV) > 20, 'String API did not compile');
    CheckEntryName(Compilation, 'Main');
    Compilation := TShaderCompiler.Compile('procedure Main; begin end;', '', True, 'main');
    CheckEntryName(Compilation, 'main');
    for BadName in TArray<string>.Create('', '1bad', 'bad name', 'a' + #0 + 'b', StringOfChar('K', 128)) do
    begin
      Rejected := False;
      try
        TShaderCompiler.Compile('procedure Main; begin end;', '', False, BadName);
      except
        on E: EArgumentException do
          Rejected := True;
      end;
      Check(Rejected, 'String API accepted an invalid external entry name');
    end;
    CheckStringMode('{$I ''missing.inc''}' + #10 + 'procedure Main; begin end;');
    CheckStringMode('uses Missing; procedure Main; begin end;');
    ShaderPath := TPath.GetFullPath(ParamStr(1));
    Rejected := False;
    try
      TShaderCompiler.CompileFile(ShaderPath, nil, '', False, '');
    except
      on E: EArgumentException do
        Rejected := True;
    end;
    Check(Rejected, 'File API accepted an empty external entry name');
    OriginalOutput := ChangeFileExt(ShaderPath, '.spv');
    HadOutput := TFile.Exists(OriginalOutput);
    Compilation := TShaderCompiler.CompileFile(ShaderPath, TArray<string>.Create(ParamStr(2)), 'APIBindings');
    Check(Length(Compilation.SPIRV) > 20, 'File API did not compile');
    Check(Pos('unit APIBindings;', Compilation.Bindings) <> 0, 'Bindings option did not reach the file API');
    Check(TFile.Exists(OriginalOutput) = HadOutput, 'File API wrote an output file');
    CheckEntryName(Compilation, 'Main');
    Compilation := TShaderCompiler.CompileFile(ShaderPath, TArray<string>.Create(ParamStr(2)), '', False, 'Kernel_42');
    CheckEntryName(Compilation, 'Kernel_42');
    Check(TFile.Exists(OriginalOutput) = HadOutput, 'Renamed file API wrote an output file');
    Sources := LoadSourceProgram(ShaderPath, TArray<string>.Create(ParamStr(2)));
    try
      Rejected := False;
      try
        TShaderCompiler.CompileResolved(Sources, '', False, 'a' + #0 + 'b');
      except
        on E: EArgumentException do
          Rejected := True;
      end;
      Check(Rejected, 'Resolved API accepted NUL in the external entry name');
      Compilation := TShaderCompiler.CompileResolved(Sources, '', True, 'main');
      CheckEntryName(Compilation, 'main');
      Compilation := TShaderCompiler.CompileResolved(Sources);
      CheckEntryName(Compilation, 'Main'); // Reuse must not inherit the last name.
    finally
      Sources.Free;
    end;
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
