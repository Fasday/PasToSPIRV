program AuditNumericCheck;

{$APPTYPE CONSOLE}
{$WARN SYMBOL_PLATFORM OFF}

uses
  System.SysUtils, System.Math, System.Hash,
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

function Digest(const Source: string): string;
var C: TCompilationResult; Hash: THashSHA2;
begin
  C := TShaderCompiler.Compile(Source);
  Hash := THashSHA2.Create; Hash.Update(C.SPIRV); Result := Hash.HashAsString;
end;

const
  BoundarySource = 'const C: Single = 1.00000006; var [Binding(0,0)] Data: array of Single; procedure Main; begin Data[0] := C; end;';
  TinySource = 'const C: Single = 1e-40; var [Binding(0,0)] Data: array of Single; procedure Main; begin Data[0] := C; end;';
var
  Saved, Before: Cardinal;
  NearestHash, DirectedHash, TinyHash, FlushedHash: string;
  Restored, ErrorRestored, NilRejected: Boolean;
begin
  Saved := GetMXCSR;
  try
    NilRejected := False;
    try TShaderCompiler.CompileResolved(nil);
    except on E: EArgumentException do NilRejected := True; end;
    if not NilRejected then raise EInvalidOpException.Create('Nil source program must produce an argument error');
    SetMXCSR($1F80);
    NearestHash := Digest(BoundarySource);
    TinyHash := Digest(TinySource);
    SetMXCSR($3F80); // round toward -infinity, exceptions masked
    Before := GetMXCSR;
    DirectedHash := Digest(BoundarySource);
    Restored := GetMXCSR = Before;
    SetMXCSR($9FC0); // nearest, flush-to-zero and denormals-are-zero
    Before := GetMXCSR;
    FlushedHash := Digest(TinySource);
    Restored := Restored and (GetMXCSR = Before);
    SetMXCSR($7F80);
    Before := GetMXCSR;
    try TShaderCompiler.Compile('const C = 1 div 0; procedure Main; begin end;');
    except on E: EShaderError do ; end;
    ErrorRestored := GetMXCSR = Before;
    Writeln('rounding-independent=', BoolToStr(NearestHash = DirectedHash,True));
    Writeln('denormal-independent=', BoolToStr(TinyHash = FlushedHash,True));
    Writeln('caller-state-restored=', BoolToStr(Restored and ErrorRestored,True));
    if ParamStr(1) <> '--probe' then
      if (NearestHash <> DirectedHash) or (TinyHash <> FlushedHash) or not Restored or not ErrorRestored then
        raise EInvalidOpException.Create('Compiler inherits or leaks caller floating-point state');
  finally SetMXCSR(Saved); end;
end.
