program PasToSPIRV;

{$APPTYPE CONSOLE}
{$BOOLEVAL OFF}
{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

uses
  Winapi.Windows,
  Winapi.ShellAPI,
  System.Math,
  System.SysUtils,
  System.IOUtils,
  System.Hash,
  PTS.Compiler in 'PTS.Compiler.pas',
  PTS.Diagnostics in 'PTS.Diagnostics.pas',
  PTS.Source in 'PTS.Source.pas',
  PTS.SourceLoader in 'PTS.SourceLoader.pas',
  PTS.ConstEval in 'PTS.ConstEval.pas',
  PTS.FloatEnvironment in 'PTS.FloatEnvironment.pas',
  PTS.FileSafety in 'PTS.FileSafety.pas',
  PTS.Names in 'PTS.Names.pas',
  PTS.Analysis in 'PTS.Analysis.pas',
  PTS.FloatLiteral in 'PTS.FloatLiteral.pas',
  PTS.Features in 'PTS.Features.pas',
  PTS.Project in 'PTS.Project.pas',
  PTS.IR in 'PTS.IR.pas',
  PTS.Types in 'PTS.Types.pas',
  PTS.Layout in 'PTS.Layout.pas',
  PTS.Reflection in 'PTS.Reflection.pas',
  PTS.Bindings in 'PTS.Bindings.pas',
  PTS.Lexer in 'PTS.Lexer.pas',
  PTS.Parser in 'PTS.Parser.pas',
  PTS.SPIRV in 'PTS.SPIRV.pas';

var
  Arguments: TArray<string>;

procedure LoadArguments;
var
  Count, I: Integer;
  Items: PPWideChar;
begin
  // ParamStr drops empty "" tokens, which would turn `-o "" file` into `-o file`.
  Items := CommandLineToArgvW(GetCommandLineW, Count);
  if Items = nil then RaiseLastOSError;
  try
    SetLength(Arguments, Max(Count - 1, 0));
    for I := 1 to Count - 1 do
      Arguments[I - 1] := PPWideChar(NativeUInt(Items) + NativeUInt(I) * SizeOf(PWideChar))^;
  finally
    LocalFree(HLOCAL(Items));
  end;
end;

function ArgCount: Integer;
begin
  Result := Length(Arguments);
end;

function Arg(AIndex: Integer): string;
begin
  if (AIndex >= 1) and (AIndex <= Length(Arguments)) then Result := Arguments[AIndex - 1]
  else Result := '';
end;

procedure PrintUsage;
begin
  Writeln('PasToSPIRV ', CompilerVersion, ' - Pascal compute shaders to SPIR-V');
  Writeln;
  Writeln('Usage: pastospirv [compile] <input.pas> [-o <output.spv>]');
  Writeln('                 [--reflection <output.json>]');
  Writeln('                 [--bindings <UnitName.pas>]');
  Writeln('                 [-I <include-directory>] ...');
  Writeln('                 [-O0|-O1]');
  Writeln('       pastospirv build <project.json> [--force]');
  Writeln('       pastospirv --version');
  Writeln('       pastospirv --help');
  Writeln;
  Writeln('Default outputs: <input>.spv and <output>.json');
  Writeln('Default: SPIR-V 1.0 / Vulkan 1.0, compute entry point Main');
  Writeln('Optional [Vulkan12] on Main: SPIR-V 1.3 / Vulkan 1.2; see docs/extended.md');
end;

function RunBuild: Integer;
var Statistics: TBuildStatistics; Path: string;
begin
  Result := 2;
  if (ArgCount < 2) or (ArgCount > 3) or ((ArgCount = 3) and (Arg(3) <> '--force')) then
  begin Writeln(ErrOutput,'Usage: pastospirv build project.json [--force]'); Exit; end;
  try
    Statistics := BuildProject(Arg(2),ArgCount = 3,THashSHA2.GetHashStringFromFile(GetModuleName(HInstance)));
    Writeln('Built: ',Statistics.Built,'; cached: ',Statistics.Cached,'.');
    Result := 0;
  except
    on E: EShaderError do
    begin
      Path := E.Position.FileName;
      Writeln(ErrOutput,Path,'(',E.Position.Line,',',E.Position.Column,'): error: ',E.Message); Result := 1;
    end;
    on E: Exception do Writeln(ErrOutput,'error: ',E.Message);
  end;
end;

function Run: Integer;
var
  InputPath, OutputPath, ReflectionPath, BindingsPath, BindingsUnit, Argument, ErrorPath: string;
  IncludeDirectories: TArray<string>;
  I: Integer;
  Compilation: TCompilationResult;
  Optimize: Boolean;
  Sources: TSourceProgram;
  SourceFile: TSourceFile;
begin
  Result := 2;
  Optimize := False;
  if ArgCount = 0 then
  begin
    PrintUsage;
    Exit;
  end;
  if (ArgCount = 1) and (Arg(1) = '--help') then
  begin
    PrintUsage;
    Exit(0);
  end;
  if (ArgCount = 1) and (Arg(1) = '--version') then
  begin
    Writeln('PasToSPIRV ', CompilerVersion);
    Exit(0);
  end;
  if SameText(Arg(1),'build') then Exit(RunBuild);
  InputPath := '';
  OutputPath := '';
  ReflectionPath := '';
  BindingsPath := '';
  BindingsUnit := '';
  I := 1;
  if SameText(Arg(I), 'compile') then
    Inc(I);
  while I <= ArgCount do
  begin
    Argument := Arg(I);
    if (Argument = '-O0') or (Argument = '-O1') then Optimize := Argument = '-O1'
    else if (Argument = '-o') or (Argument = '--reflection') or (Argument = '--bindings') or
      (Argument = '-I') or (Argument = '--include') then
    begin
      Inc(I);
      if (I > ArgCount) or (Arg(I) = '') or
        (Copy(Arg(I), 1, 1) = '-') then
      begin
        Writeln(ErrOutput, 'error: missing path after ', Argument);
        Exit;
      end;
      if Argument = '-o' then
      begin
        if OutputPath <> '' then
        begin
          Writeln(ErrOutput, 'error: duplicate -o option');
          Exit;
        end;
        OutputPath := Arg(I);
      end
      else if Argument = '--reflection' then
      begin
        if ReflectionPath <> '' then
        begin
          Writeln(ErrOutput, 'error: duplicate --reflection option');
          Exit;
        end;
        ReflectionPath := Arg(I);
      end
      else if Argument = '--bindings' then
      begin
        if BindingsPath <> '' then
        begin
          Writeln(ErrOutput, 'error: duplicate --bindings option');
          Exit;
        end;
        BindingsPath := Arg(I);
      end
      else
      begin
        SetLength(IncludeDirectories, Length(IncludeDirectories) + 1);
        IncludeDirectories[High(IncludeDirectories)] := Arg(I);
      end;
    end
    else if (Argument = '') or (Argument[1] = '-') then
    begin
      Writeln(ErrOutput, 'error: unknown option ', Argument);
      Exit;
    end
    else if InputPath = '' then
      InputPath := Argument
    else
    begin
      Writeln(ErrOutput, 'error: only one input file is accepted');
      Exit;
    end;
    Inc(I);
  end;
  if InputPath = '' then
  begin
    Writeln(ErrOutput, 'error: input file is required');
    Exit;
  end;
  try
    InputPath := TPath.GetFullPath(InputPath);
    if OutputPath = '' then
      OutputPath := ChangeFileExt(InputPath, '.spv');
    OutputPath := TPath.GetFullPath(OutputPath);
    if ReflectionPath = '' then
      ReflectionPath := ChangeFileExt(OutputPath, '.json');
    ReflectionPath := TPath.GetFullPath(ReflectionPath);
    ValidateOutputPath(OutputPath);
    ValidateOutputPath(ReflectionPath);
    if SameFileOrPath(InputPath, OutputPath) or SameFileOrPath(InputPath, ReflectionPath) or
      SameFileOrPath(OutputPath, ReflectionPath) then
    begin
      Writeln(ErrOutput, 'error: input, SPIR-V and reflection paths must be different');
      Exit;
    end;
    if BindingsPath <> '' then
    begin
      BindingsPath := TPath.GetFullPath(BindingsPath);
      ValidateOutputPath(BindingsPath);
      if SameFileOrPath(BindingsPath, InputPath) or SameFileOrPath(BindingsPath, OutputPath) or
        SameFileOrPath(BindingsPath, ReflectionPath) then
        raise EArgumentException.Create('Bindings path must differ from input, SPIR-V and reflection');
      if not SameText(TPath.GetExtension(BindingsPath), '.pas') then
        raise EArgumentException.Create('Bindings output must have a .pas extension');
      BindingsUnit := TPath.GetFileNameWithoutExtension(BindingsPath);
      if BindingsUnit = '' then
        raise EArgumentException.Create('Bindings filename must contain a Delphi unit name');
    end;
    Sources := LoadSourceProgram(InputPath, IncludeDirectories);
    try
      for SourceFile in Sources.Files do
        if SameFileOrPath(SourceFile.FullPath,OutputPath) or SameFileOrPath(SourceFile.FullPath,ReflectionPath) or
          ((BindingsPath <> '') and SameFileOrPath(SourceFile.FullPath,BindingsPath)) then
          raise EArgumentException.Create('Output path collides with a source dependency');
      Compilation := TShaderCompiler.CompileResolved(Sources, BindingsUnit, Optimize);
    finally Sources.Free; end;
    // Do not touch outputs until parsing, type checking and generation succeed.
    TDirectory.CreateDirectory(TPath.GetDirectoryName(OutputPath));
    TDirectory.CreateDirectory(TPath.GetDirectoryName(ReflectionPath));
    TFile.WriteAllBytes(OutputPath, Compilation.SPIRV);
    TFile.WriteAllBytes(ReflectionPath, TEncoding.UTF8.GetBytes(Compilation.Reflection));
    Writeln(OutputPath);
    Writeln(ReflectionPath);
    if BindingsPath <> '' then
    begin
      TDirectory.CreateDirectory(TPath.GetDirectoryName(BindingsPath));
      TFile.WriteAllBytes(BindingsPath, TEncoding.UTF8.GetBytes(Compilation.Bindings));
      Writeln(BindingsPath);
    end;
    Result := 0;
  except
    on E: EShaderError do
    begin
      ErrorPath := E.Position.FileName;
      if ErrorPath = '' then ErrorPath := InputPath;
      Writeln(ErrOutput, ErrorPath, '(', E.Position.Line, ',', E.Position.Column,
        '): error: ', E.Message);
      Result := 1;
    end;
    on E: Exception do
    begin
      Writeln(ErrOutput, 'error: ', E.Message);
      Result := 2;
    end;
  end;
end;

var
  ConsoleMode: Cardinal;
begin
  // Preserve interactive console settings; redirected diagnostics use UTF-8.
  if not GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), ConsoleMode) then
    SetTextCodePage(Output, 65001);
  if not GetConsoleMode(GetStdHandle(STD_ERROR_HANDLE), ConsoleMode) then
    SetTextCodePage(ErrOutput, 65001);
  LoadArguments;
  ExitCode := Run;
end.
