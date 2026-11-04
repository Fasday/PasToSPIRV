program SoftDoubleCheck;

// CPU reference for lib/SoftDouble.pasm: Delphi Win64 Double division (SSE2
// DIVSD) under nearest-even MXCSR without FTZ/DAZ and with masked exceptions.
// Input: pairs of binary64 bit patterns; output: the quotient bit patterns.

{$APPTYPE CONSOLE}
{$EXCESSPRECISION OFF}

uses
  System.SysUtils, System.IOUtils,
  PTS.FloatEnvironment in '..\source\PTS.FloatEnvironment.pas';

procedure Run;
var
  Input, Output: TBytes;
  I, Count: Integer;
  A, B, Q: Double;
begin
  if ParamCount <> 2 then raise EArgumentException.Create('Usage: SoftDoubleCheck pairs.bin quotients.bin');
  Input := TFile.ReadAllBytes(ParamStr(1));
  if Length(Input) mod 16 <> 0 then raise EArgumentException.Create('Expected pairs of 64-bit values');
  Count := Length(Input) div 16;
  SetLength(Output, Count * 8);
  for I := 0 to Count - 1 do
  begin
    Move(Input[I * 16], A, 8);
    Move(Input[I * 16 + 8], B, 8);
    Q := A / B;
    Move(Q, Output[I * 8], 8);
  end;
  TFile.WriteAllBytes(ParamStr(2), Output);
  Writeln('PASS: Delphi DIVSD reference for ', Count, ' pairs.');
end;

var
  State: TCompilerFloatState;
begin
  State := EnterCompilerFloatEnvironment;
  try
    try
      Run;
    except
      on E: Exception do
      begin
        Writeln(ErrOutput, E.Message);
        ExitCode := 2;
      end;
    end;
  finally
    LeaveCompilerFloatEnvironment(State);
  end;
end.
