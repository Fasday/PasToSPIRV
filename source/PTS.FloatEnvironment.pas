unit PTS.FloatEnvironment;

interface

{$IFDEF CPUX64}
type
  TCompilerFloatState = record
    MXCSR: Cardinal;
  end;
{$ELSE}
uses System.Math;
type
  TCompilerFloatState = record
    Rounding: TRoundingMode;
    Exceptions: TFPUExceptionMask;
  end;
{$ENDIF}

function EnterCompilerFloatEnvironment: TCompilerFloatState;
procedure LeaveCompilerFloatEnvironment(const AState: TCompilerFloatState);

implementation

{$WARN SYMBOL_PLATFORM OFF}

{$IFDEF CPUX64}
function EnterCompilerFloatEnvironment: TCompilerFloatState;
begin
  Result.MXCSR := GetMXCSR;
  // SSE2 nearest-even, all exceptions masked, no FTZ/DAZ, no pending status.
  // Win64 Single/Double parsing/evaluation must not inherit caller state.
  SetMXCSR($1F80);
end;

procedure LeaveCompilerFloatEnvironment(const AState: TCompilerFloatState);
begin
  // Restore status as well as control bits, including on parser/emitter errors.
  SetMXCSR(AState.MXCSR);
end;
{$ELSE}
function EnterCompilerFloatEnvironment: TCompilerFloatState;
begin
  Result.Rounding := GetRoundMode;
  Result.Exceptions := GetExceptionMask;
  SetExceptionMask([exInvalidOp,exDenormalized,exZeroDivide,exOverflow,exUnderflow,exPrecision]);
  SetRoundMode(rmNearest);
end;

procedure LeaveCompilerFloatEnvironment(const AState: TCompilerFloatState);
begin
  ClearExceptions;
  SetRoundMode(AState.Rounding);
  SetExceptionMask(AState.Exceptions);
end;
{$ENDIF}

end.
