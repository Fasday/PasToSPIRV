unit PTS.FloatEnvironment;

// Compiler entry points pin the host floating-point environment and restore the
// caller's state exactly. Windows x64/x86 access the registers directly: the RTL
// setters also rewrite process-wide defaults (DefaultMXCSR, Default8087CW), which
// the RTL loads into new threads and, on Win64, into every thread that handles an
// exception. Other targets use the portable RTL interface.

interface

{$IF Defined(MSWINDOWS) and Defined(CPUX64)}
  {$DEFINE PTS_DIRECT_MXCSR}
{$ELSEIF Defined(MSWINDOWS) and Defined(CPUX86)}
  {$DEFINE PTS_DIRECT_MXCSR}
  {$DEFINE PTS_DIRECT_X87}
{$ENDIF}

{$IFDEF PTS_DIRECT_MXCSR}
type
  TCompilerFloatState = record
    MXCSR: Cardinal;
    {$IFDEF PTS_DIRECT_X87}
    // FNSTENV image: control, status and tag words of the caller.
    Environment: array[0..27] of Byte;
    {$ENDIF}
  end;
{$ELSE}
uses System.Math;
type
  TCompilerFloatState = record
    Rounding: TRoundingMode;
    Exceptions: TArithmeticExceptionMask;
    Flags: TArithmeticExceptions;
  end;
{$ENDIF}

function EnterCompilerFloatEnvironment: TCompilerFloatState;
procedure LeaveCompilerFloatEnvironment(const AState: TCompilerFloatState);
// Handling an exception may make the RTL reload its process-wide defaults. A
// handler that lets compilation continue calls this first. No effect outside
// EnterCompilerFloatEnvironment/LeaveCompilerFloatEnvironment.
procedure PinCompilerFloatEnvironment;

implementation

threadvar
  // Nesting of compiler entry points on this thread.
  ActiveDepth: Integer;

{$IFDEF PTS_DIRECT_MXCSR}
const
  // SSE2 nearest-even, all exceptions masked, no FTZ/DAZ, no pending status.
  // Single/Double parsing/evaluation must not inherit caller state.
  PinnedMXCSR = $1F80;

{$IFDEF CPUX64}
function ReadMXCSR: Cardinal;
asm
        .NOFRAME
        STMXCSR DWORD PTR [RSP+8]
        MOV     EAX, DWORD PTR [RSP+8]
end;

procedure WriteMXCSR(AValue: Cardinal);
asm
        .NOFRAME
        MOV     DWORD PTR [RSP+8], ECX
        LDMXCSR DWORD PTR [RSP+8]
end;
{$ELSE}
function ReadMXCSR: Cardinal;
asm
        PUSH    EAX
        STMXCSR DWORD PTR [ESP]
        POP     EAX
end;

procedure WriteMXCSR(AValue: Cardinal);
asm
        PUSH    EAX
        LDMXCSR DWORD PTR [ESP]
        POP     EAX
end;
{$ENDIF}

{$IFDEF PTS_DIRECT_X87}
const
  // x87 nearest-even, 53-bit precision, all exceptions masked: conversions and
  // comparisons. Constant arithmetic itself uses SSE2 (PTS.ConstEval), because
  // the x87 rounds a Double result twice.
  PinnedControlWord = $027F;

procedure SaveEnvironment(var AEnvironment);
asm
        FNSTENV [EAX]
end;

procedure LoadControlWord(AValue: Cardinal);
asm
        PUSH    EAX
        FLDCW   WORD PTR [ESP]
        POP     EAX
end;

procedure RestoreEnvironment(const AEnvironment);
asm
        FNCLEX
        FLDENV  [EAX]
end;
{$ENDIF}

procedure Pin;
begin
  WriteMXCSR(PinnedMXCSR);
  {$IFDEF PTS_DIRECT_X87}
  LoadControlWord(PinnedControlWord);
  {$ENDIF}
end;

function EnterCompilerFloatEnvironment: TCompilerFloatState;
begin
  Result.MXCSR := ReadMXCSR;
  {$IFDEF PTS_DIRECT_X87}
  SaveEnvironment(Result.Environment);
  {$ENDIF}
  Pin;
  Inc(ActiveDepth);
end;

procedure LeaveCompilerFloatEnvironment(const AState: TCompilerFloatState);
begin
  Dec(ActiveDepth);
  // Restore status as well as control bits, including on parser/emitter errors.
  {$IFDEF PTS_DIRECT_X87}
  RestoreEnvironment(AState.Environment);
  {$ENDIF}
  WriteMXCSR(AState.MXCSR);
end;
{$ELSE}
procedure Pin;
begin
  SetExceptionMask([exInvalidOp,exDenormalized,exZeroDivide,exOverflow,exUnderflow,exPrecision]);
  SetRoundMode(rmNearest);
end;

function EnterCompilerFloatEnvironment: TCompilerFloatState;
begin
  Result.Rounding := GetRoundMode;
  Result.Exceptions := GetExceptionMask;
  Result.Flags := GetExceptions;
  Pin;
  ClearExceptions(False);
  Inc(ActiveDepth);
end;

procedure LeaveCompilerFloatEnvironment(const AState: TCompilerFloatState);
begin
  Dec(ActiveDepth);
  ClearExceptions(False);
  SetExceptions(AState.Flags);
  SetRoundMode(AState.Rounding);
  SetExceptionMask(AState.Exceptions);
end;
{$ENDIF}

procedure PinCompilerFloatEnvironment;
begin
  if ActiveDepth > 0 then
    Pin;
end;

end.
