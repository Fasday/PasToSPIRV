program SharedSourceCheck;

{$APPTYPE CONSOLE}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

uses
  System.SysUtils,
  System.IOUtils,
  System.Math;

{$I '..\examples\shared\Params.inc'}
{$I '..\examples\shared\Bits.inc'}
{$I '..\examples\shared\Math.inc'}

function Run: Integer;
var
  InputData, OutputData: TBytes;
  I: Integer;
  Bits, Code, Rounds: Cardinal;
  Value, Scaled, Factor: Single;
  ParsedRounds: UInt64;
  ParsedFactor: Double;
begin
  if SizeOf(TSharedParams) <> 12 then
    raise EInvalidOpException.Create('Shared POD record layout differs on this Delphi target');
  if ParamCount <> 4 then
    raise EArgumentException.Create('Usage: SharedSourceCheck integer|single input.bin output.bin rounds|factor');
  Rounds := 0;
  Factor := 0;
  if SameText(ParamStr(1), 'integer') then
  begin
    if not TryStrToUInt64(ParamStr(4), ParsedRounds) or (ParsedRounds > 1024) then
      raise EArgumentException.Create('Rounds must be in 0..1024');
    Rounds := Cardinal(ParsedRounds);
  end
  else if SameText(ParamStr(1), 'single') then
  begin
    if not TryStrToFloat(ParamStr(4), ParsedFactor, TFormatSettings.Invariant) or
      IsNan(ParsedFactor) or IsInfinite(ParsedFactor) or (Abs(ParsedFactor) > 3.4028234663852886E38) then
      raise EArgumentException.Create('Factor must be a finite Single');
    Factor := ParsedFactor;
  end
  else
    raise EArgumentException.Create('Expected integer or single mode');
  InputData := TFile.ReadAllBytes(ParamStr(2));
  if (Length(InputData) mod 4 <> 0) or (Length(InputData) > 1024 * 1024) then
    raise EArgumentException.Create('Expected at most 1 MiB of 32-bit input values');
  SetLength(OutputData, Length(InputData));
  for I := 0 to Length(InputData) div 4 - 1 do
    if SameText(ParamStr(1), 'integer') then
    begin
      Move(InputData[I * 4], Bits, 4);
      Code := TransformCode(Bits, Rounds);
      Move(Code, OutputData[I * 4], 4);
    end
    else
    begin
      Move(InputData[I * 4], Value, 4);
      Scaled := ScaleValue(Value, Factor);
      Move(Scaled, OutputData[I * 4], 4);
    end;
  TFile.WriteAllBytes(ParamStr(3), OutputData);
  Writeln('PASS: common source compiled by Delphi (', Length(InputData) div 4, ' values).');
  Result := 0;
end;

begin
  try
    ExitCode := Run;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.Message);
      ExitCode := 1;
    end;
  end;
end.
