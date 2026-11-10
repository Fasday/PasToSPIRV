program FloatStateCheck;

// The compiler neither depends on nor disturbs the host floating-point state:
// of the calling thread, of other threads, and of the process-wide RTL defaults.
// Usage: FloatStateCheck <tests/fixtures/host_constants.pas>

{$APPTYPE CONSOLE}
{$BOOLEVAL OFF}
{$WARN SYMBOL_PLATFORM OFF}

uses
  System.SysUtils, System.Classes, System.IOUtils,
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
  PTS.Graphics in '..\source\PTS.Graphics.pas',
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
  // The compiler handles an exception internally (an overload candidate whose
  // exact constant check overflows Int64) and then folds 1.0 / 3.0.
  HandledSource =
    'var [Binding(0,0), WriteOnly] Data: array of Single;' + #10 +
    'function Pick(A: Integer): Integer; overload; begin Result := A; end;' + #10 +
    'function Pick(A: Cardinal): Integer; overload; begin Result := 1; end;' + #10 +
    'procedure Main;' + #10 +
    'begin' + #10 +
    '  Data[0] := Single(Pick(65536 * 65536 * 65536 * 65536 * 65536));' + #10 +
    '  const K = 1.0 / 3.0;' + #10 +
    '  Data[1] := K;' + #10 +
    'end;';
  BrokenSource = 'const C = 1 div 0; procedure Main; begin end;';

var
  ConstantSource: string;
  ConstantBaseline, HandledBaseline: TBytes;

procedure Check(Value: Boolean; const MessageText: string);
begin
  if not Value then
    raise Exception.Create(MessageText);
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and (Length(A) > 0) and CompareMem(@A[0], @B[0], Length(A));
end;

function CompileConstants: TBytes;
begin
  Result := TShaderCompiler.Compile(ConstantSource).SPIRV;
end;

function CompileHandled: TBytes;
begin
  Result := TShaderCompiler.Compile(HandledSource).SPIRV;
end;

procedure CompileBroken;
begin
  try
    TShaderCompiler.Compile(BrokenSource);
    raise Exception.Create('The broken source was accepted');
  except
    on E: EShaderError do
      ;
  end;
end;

// SPIR-V words are little-endian; a 64-bit literal is stored low word first.
function HasWords(const Code: TBytes; const Words: array of Cardinal): Boolean;
var
  I, J: Integer;
  Value: Cardinal;
  Match: Boolean;
begin
  I := 0;
  while I + Length(Words) * 4 <= Length(Code) do
  begin
    Match := True;
    for J := 0 to High(Words) do
    begin
      Move(Code[I + J * 4], Value, 4);
      if Value <> Words[J] then
      begin
        Match := False;
        Break;
      end;
    end;
    if Match then
      Exit(True);
    Inc(I, 4);
  end;
  Result := False;
end;

procedure CheckConstants(const Code: TBytes; const Context: string);
const
  Doubles: array[0..4] of UInt64 = ($40CD035B4D466271, $3F1356BEDC4E782B, $0001BC0CF1AB87DD,
    $0000483ECF74B2E3, $3FD5555555555555);
  Singles: array[0..4] of Cardinal = ($3EAAAAAB, $3CF5C290, $000116C2, $3DCCCCCD, $4B800000);
var
  D: UInt64;
  S: Cardinal;
begin
  for D in Doubles do
    Check(HasWords(Code, [Cardinal(D), Cardinal(D shr 32)]),
      Context + ': binary64 constant ' + IntToHex(D, 16) + ' is not correctly rounded');
  for S in Singles do
    Check(HasWords(Code, [S]), Context + ': binary32 constant ' + IntToHex(S, 8) + ' is not correctly rounded');
  Check(HasWords(Code, [$92345678]), Context + ': the Double to Integer conversion is wrong');
end;

{$IFDEF CPUX64}
type
  // Another thread of the application, handling ordinary exceptions. On Win64 the
  // RTL then reloads the process-wide DefaultMXCSR into that thread.
  TBystander = class(TThread)
  public
    Initial, Observed: Cardinal;
    Rounds: Integer;
  protected
    procedure Execute; override;
  end;

  TPeer = class(TThread)
  public
    Rounds: Integer;
  protected
    procedure Execute; override;
  end;

procedure TBystander.Execute;
begin
  Initial := GetMXCSR and $FFC0;
  Observed := Initial;
  while not Terminated and (Observed = Initial) do
  begin
    try
      raise EConvertError.Create('ordinary application exception');
    except
      on E: EConvertError do
        ;
    end;
    Inc(Rounds);
    Observed := GetMXCSR and $FFC0;
  end;
end;

procedure TPeer.Execute;
begin
  SetMXCSR($7F80); // this thread's own state: round toward zero
  while not Terminated do
  begin
    TShaderCompiler.Compile('procedure Main; begin end;');
    Inc(Rounds);
  end;
end;

procedure CheckHost;
var
  SavedThread, SavedDefault: Cardinal;
  Bystander: TBystander;
  Peer: TPeer;
  I: Integer;
begin
  SavedThread := GetMXCSR;
  SavedDefault := DefaultMXCSR;
  try
    // Sticky status flags of the caller survive, also when compilation fails.
    SetMXCSRExceptionFlag($3F);
    CheckConstants(CompileConstants, 'status flags set');
    Check(GetMXCSR and $3F = $3F, 'Caller MXCSR status flags were not restored');
    CompileBroken;
    Check(GetMXCSR and $3F = $3F, 'Caller MXCSR status flags were not restored after an error');
    SetMXCSRExceptionFlag(0);

    // A thread-private state (rounding toward zero, FTZ/DAZ, unmasked) is not
    // inherited and does not become the process default.
    SetMXCSR($E040);
    DefaultMXCSR := SavedDefault;
    Check(SameBytes(CompileConstants, ConstantBaseline), 'Constants depend on the caller MXCSR');
    Check(SameBytes(CompileHandled, HandledBaseline), 'A handled exception exposed the caller MXCSR');
    CompileBroken;
    Check(GetMXCSR = $E040, 'Caller MXCSR was not restored');
    Check(DefaultMXCSR = SavedDefault, 'Compilation changed the process-wide DefaultMXCSR');

    // The RTL reloads DefaultMXCSR when an exception is handled: with a process
    // default of rounding toward zero the compiler must pin its state again.
    SetMXCSR($7F80);
    Check(SameBytes(CompileHandled, HandledBaseline), 'A handled exception exposed the process default MXCSR');
    Check((GetMXCSR = $7F80) and (DefaultMXCSR = $7F80), 'Caller or process MXCSR changed');

    // Classic Delphi setting: invalid operation, zero divide and overflow raise.
    SetMXCSR($1900);
    Bystander := TBystander.Create(True);
    try
      Bystander.Start;
      while (Bystander.Rounds = 0) and not Bystander.Finished do
        Sleep(1);
      for I := 1 to 300 do
        CompileHandled;
      Bystander.Terminate;
      Bystander.WaitFor;
      Check(Bystander.Observed = Bystander.Initial, Format(
        'Compilation changed the MXCSR of another thread: %.4x -> %.4x', [Bystander.Initial, Bystander.Observed]));
      Check(Bystander.Initial = $1900, 'The bystander thread did not start with the process default');
    finally
      Bystander.Free;
    end;

    // Two threads compiling at once; the peer's caller state rounds toward zero.
    SetMXCSR(SavedThread);
    DefaultMXCSR := SavedDefault;
    Peer := TPeer.Create(True);
    try
      Peer.Start;
      while (Peer.Rounds = 0) and not Peer.Finished do
        Sleep(1);
      for I := 1 to 3000 do
        Check(SameBytes(CompileHandled, HandledBaseline), 'A concurrent compilation changed a folded constant');
      Peer.Terminate;
      Peer.WaitFor;
      Check((Peer.FatalException = nil) and (Peer.Rounds > 0), 'The concurrent compilation thread failed');
    finally
      Peer.Free;
    end;
  finally
    SetMXCSR(SavedThread);
    DefaultMXCSR := SavedDefault;
  end;
end;
{$ELSE}
procedure CheckHost;
const
  // Delphi classic, 53-bit and 24-bit precision control, MSVC default, chop.
  ControlWords: array[0..5] of Word = ($1332, $1232, $1032, $027F, $1F32, $1C3F);
var
  SavedControl, SavedDefaultControl, ControlWord: Word;
  SavedMXCSR: Cardinal;
begin
  SavedControl := Get8087CW;
  SavedDefaultControl := Default8087CW;
  SavedMXCSR := GetMXCSR;
  try
    for ControlWord in ControlWords do
    begin
      Set8087CW(ControlWord);
      Default8087CW := SavedDefaultControl;
      Check(SameBytes(CompileConstants, ConstantBaseline),
        'Constants depend on the caller x87 control word $' + IntToHex(ControlWord, 4));
      CompileBroken;
      // Bit 6 is reserved and reads back as set.
      Check(Get8087CW and $1F3F = ControlWord and $1F3F, 'Caller x87 control word was not restored');
      Check(Default8087CW = SavedDefaultControl, 'Compilation changed the process-wide Default8087CW');
    end;
    Set8087CW(SavedControl);
    SetMXCSR($E040);
    DefaultMXCSR := SavedMXCSR and $FFC0;
    Check(SameBytes(CompileConstants, ConstantBaseline), 'Constants depend on the caller MXCSR');
    Check(GetMXCSR and $FFC0 = $E040, 'Caller MXCSR was not restored');
    Check(DefaultMXCSR = SavedMXCSR and $FFC0, 'Compilation changed the process-wide DefaultMXCSR');
  finally
    Set8087CW(SavedControl);
    Default8087CW := SavedDefaultControl;
    SetMXCSR(SavedMXCSR);
    DefaultMXCSR := SavedMXCSR and $FFC0;
  end;
end;
{$ENDIF}

begin
  try
    if ParamCount <> 1 then
      raise Exception.Create('Usage: FloatStateCheck <host_constants.pas>');
    ConstantSource := TFile.ReadAllText(ParamStr(1), TEncoding.UTF8);
    ConstantBaseline := CompileConstants;
    HandledBaseline := CompileHandled;
    CheckConstants(ConstantBaseline, 'default state');
    Check(HasWords(HandledBaseline, [$3EAAAAAB]), 'Default state: 1.0 / 3.0 is not correctly rounded');
    CheckHost;
    Writeln('PASS: host floating-point state is neither inherited nor disturbed (', SizeOf(Pointer) * 8, '-bit host).');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
