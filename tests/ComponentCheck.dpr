program ComponentCheck;

{$APPTYPE CONSOLE}
{$BOOLEVAL OFF}

uses
  System.SysUtils, System.Classes, System.IOUtils,
  PTS.Component in '..\source\PTS.Component.pas',
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

const
  Plain = 'var [Binding(0,0)] Output: array of Cardinal;' + #10 +
    'procedure Main; begin Output[0] := 41 + 1; end;';
  Root = 'uses Values;' + #10 +
    'var [Binding(0,0)] Output: array of Cardinal;' + #10 +
    'procedure Main; begin Output[0] := Values.Answer(); end;';
  Values = 'module Values;' + #10 +
    'function Answer(): Cardinal; begin Result := 42; end;';

procedure Check(Value: Boolean; const MessageText: string);
begin
  if not Value then
    raise Exception.Create(MessageText);
end;

procedure SameCode(const A, B: TCompilationResult);
begin
  Check(Length(A.SPIRV) = Length(B.SPIRV), 'Different SPIR-V sizes');
  Check((Length(A.SPIRV) > 0) and CompareMem(@A.SPIRV[0], @B.SPIRV[0], Length(A.SPIRV)),
    'Different SPIR-V bytes');
end;

procedure ExpectError(const Source: string; const Dependencies: TArray<TSourceText>;
  const Search: TArray<string>; const MessageText: string; const FileName: string = '');
begin
  try
    TShaderCompiler.CompileText(Source, 'Main.pas', Dependencies, Search);
  except
    on E: EShaderError do
    begin
      Check(Pos(MessageText, E.Message) <> 0, 'Unexpected diagnostic: ' + E.Message);
      if FileName <> '' then
        Check(E.Position.FileName = FileName, 'Dependency diagnostic lost its source name');
      Exit;
    end;
  end;
  raise Exception.Create('Expected source error: ' + MessageText);
end;

procedure Run;
var
  Compiler: TShaderCompilerComponent;
  Source, A, B: TCompilationResult;
  Sources: TArray<TSourceText>;
  OriginalDirectory, Directory: string;
begin
  Compiler := TShaderCompilerComponent.Create(nil);
  try
    Check(Compiler.SourceName = 'shader.pas', 'Component has no default source name');
    SameCode(TShaderCompiler.Compile(Plain), Compiler.Compile(Plain));
    SameCode(TShaderCompiler.Compile(Plain), Compiler.Compile(#$FEFF + Plain.Replace(#10, #13#10)));
    Compiler.Optimize := True;
    SameCode(TShaderCompiler.Compile(Plain, '', True), Compiler.Compile(Plain));
    Compiler.EntryPointName := 'main';
    SameCode(TShaderCompiler.Compile(Plain, '', True, 'main'), Compiler.Compile(Plain));
    Compiler.EntryPointName := 'Main';
    Compiler.Optimize := False;
    Compiler.SourceName := 'Main.pas';
    Sources := [TSourceText.Create('Values.pasm', Values)];
    A := Compiler.Compile(Root, Sources);
    SameCode(A, TShaderCompiler.CompileText(Root, 'Main.pas', Sources));
    Check(Pos('Values.pasm', A.Reflection) <> 0, 'Missing module dependency reflection');
    Check(Pos('Main.pas', A.Reflection) <> 0, 'Missing entry source reflection');
    TFile.WriteAllBytes('build\component.spv', A.SPIRV);

    Source := Compiler.Compile('{$I ''body.pasm''}', [TSourceText.Create('body.pasm', Plain)]);
    SameCode(TShaderCompiler.Compile(Plain), Source);
    ExpectError('{$I ''broken.pasm''}', [TSourceText.Create('broken.pasm',
      'procedure Main; begin Missing := 1; end;')], nil, 'Missing', 'broken.pasm');

    Sources := [TSourceText.Create('lib/Values.pasm', Values)];
    Compiler.SearchDirectories.Add('lib');
    B := Compiler.Compile(Root, Sources);
    SameCode(A, B);
    Compiler.SearchDirectories.Clear;
    SameCode(A, Compiler.Compile(Root, [TSourceText.Create('./Values.pasm', Values)]));
    SameCode(A, TShaderCompiler.CompileText(Root, 'Main.pas',
      [TSourceText.Create('Values.pasm', Values)], ['']));

    ExpectError(Root, nil, nil, 'Dependency not found');
    ExpectError(Root, [TSourceText.Create('a/Values.pasm', Values),
      TSourceText.Create('b/Values.pasm', Values)], ['a', 'b'], 'Ambiguous dependency');
    ExpectError('uses A; procedure Main; begin end;', [
      TSourceText.Create('A.pasm', 'module A; uses B; const One = 1;'),
      TSourceText.Create('B.pasm', 'module B; uses A; const Two = 2;')], nil, 'Module cycle');
    ExpectError('{$I ''loop.pasm''}', [TSourceText.Create('loop.pasm',
      '{$I ''Main.pas''}')], nil, 'Include cycle');
    ExpectError('{$I ''../outside.pasm''}', nil, nil, 'escapes its namespace');
    // As in file mode, a directory which cannot hold the name is skipped when
    // another search directory resolves it.
    SameCode(TShaderCompiler.Compile(Plain), TShaderCompiler.CompileText('{$I ''../body.pasm''}',
      'Main.pas', [TSourceText.Create('lib/body.pasm', Plain)], ['lib/sub']));
    ExpectError('{$I ''../body.pasm''}', [TSourceText.Create('lib/body.pasm', Plain)], ['other'],
      'escapes its namespace');
    try
      Compiler.Compile(Root, [TSourceText.Create('Values.pasm', Values),
        TSourceText.Create('./Values.pasm', Values)]);
      raise Exception.Create('Duplicate virtual sources were accepted');
    except
      on E: EArgumentException do
        Check(Pos('Duplicate virtual source', E.Message) <> 0, E.Message);
    end;

    OriginalDirectory := GetCurrentDir;
    Directory := TPath.GetFullPath('build\component-files');
    TDirectory.CreateDirectory(Directory);
    TFile.WriteAllText(TPath.Combine(Directory, 'Values.pasm'), Values, TEncoding.UTF8);
    try
      SetCurrentDir(Directory);
      ExpectError(Root, nil, nil, 'Dependency not found');
    finally
      SetCurrentDir(OriginalDirectory);
    end;
    Writeln('Component source, module, include, isolation and diagnostic checks passed');
  finally
    Compiler.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
