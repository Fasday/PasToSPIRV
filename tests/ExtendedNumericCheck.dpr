program ExtendedNumericCheck;

{$APPTYPE CONSOLE}
{$Q-}
{$R-}
{$EXCESSPRECISION OFF}

uses
  System.SysUtils, System.Math, System.IOUtils,
  PTS.FloatEnvironment in '..\source\PTS.FloatEnvironment.pas';

type TRow = array[0..27] of UInt64;

function Bits(D: Double): UInt64;
begin Move(D, Result, 8); end;

function FromBits(U: UInt64): Double;
begin Move(U, Result, 8); end;

function Rounded32(D: Double; Up: Boolean): Int64;
var V: Int64;
begin
  Result := Low(Integer);
  if IsNan(D) or IsInfinite(D) or (D <= -2147483649.0) or (D >= 2147483649.0) then Exit;
  V := System.Trunc(D);
  if Up then begin if D > V then Inc(V); end
  else if D < V then Dec(V);
  if (V >= Low(Integer)) and (V <= High(Integer)) then Result := V;
end;

procedure Run;
const
  Lookup: array[0..3] of Int64 = (7, -3, 1234567890123, Low(Int64));
var
  Input, Floats, Output: TBytes;
  Row: TRow;
  I, Count, J: Integer;
  U, Shifted: UInt64;
  S, SignedShift: Int64;
  D, Rounded: Double;
  F: Single;
  RawSingle: Cardinal;
begin
  Input := TFile.ReadAllBytes(ParamStr(1)); Floats := TFile.ReadAllBytes(ParamStr(2));
  if (Length(Input) mod 8 <> 0) or (Length(Input) <> Length(Floats)) then raise Exception.Create('Bad input size');
  Count := Length(Input) div 8; SetLength(Output, Count * SizeOf(TRow));
  for I := 0 to Count - 1 do
  begin
    Move(Input[I*8], U, 8); Move(U, S, 8); Move(Floats[I*8], D, 8);
    Row[0] := U + UInt64($FEDCBA9876543210);
    Row[1] := U - UInt64(123456789); Row[2] := U * UInt64(4294967297);
    Row[3] := U div 7; Row[4] := U mod 7;
    Row[5] := U shr (I and 63); Row[6] := U shl (I and 63);
    Row[7] := UInt64(S div Int64(7)); Row[8] := UInt64(S mod Int64(7));
    Row[9] := UInt64(S) shr (I and 63);
    Shifted := U shr (I and 63);
    if (S < 0) and (I and 63 <> 0) then Shifted := Shifted or (High(UInt64) shl (64 - (I and 63)));
    Move(Shifted, SignedShift, 8); Row[10] := UInt64(SignedShift);
    Row[11] := Ord(U > UInt64($8000000000000000)); Row[12] := Ord(S < 0);
    if IsNan(D) or IsInfinite(D) then
    begin
      Row[13] := UInt64(Low(Int64)); Row[14] := UInt64(Low(Int64));
      Row[15] := UInt64(Int64(Low(Integer))); Row[16] := UInt64(Int64(Low(Integer)));
      Rounded := D;
    end
    else
    begin
      // These probes are bounded for integer conversions; use real Delphi Round
      // under the isolated nearest-even MXCSR, not a Python reimplementation.
      if (D >= -9223372036854775808.0) and (D < 9223372036854775808.0) then
      begin Row[13] := UInt64(System.Round(D)); Row[14] := UInt64(System.Trunc(D)); end
      else begin Row[13] := UInt64(Low(Int64)); Row[14] := UInt64(Low(Int64)); end;
      Row[15] := UInt64(Rounded32(D, False)); Row[16] := UInt64(Rounded32(D, True));
      if Abs(D) < 9223372036854775808.0 then Rounded := System.Round(D) else Rounded := D;
      if (Bits(D) and UInt64($8000000000000000) <> 0) and (Rounded = 0) then
        Rounded := FromBits($8000000000000000);
    end;
    Row[17] := Bits(Rounded); Row[18] := Bits(D + 0.125); Row[19] := Bits(D * 2);
    Row[20] := Bits(D * 0.125);
    Row[21] := High(UInt64); Row[22] := High(UInt64);
    for J := 0 to 31 do if (Cardinal(U) and (Cardinal(1) shl J)) <> 0 then
    begin Row[21] := J; if Row[22] = High(UInt64) then Row[22] := J; end;
    Row[23] := UInt64(Lookup[I and 3]);
    Row[24] := Byte((I * 3) + I); Row[25] := Word((I * 1009) xor (I * 257));
    RawSingle := Cardinal(U); Move(RawSingle, F, 4); Move(F, RawSingle, 4);
    Row[26] := RawSingle; Row[27] := Ord(IsNan(D) or IsInfinite(D));
    Move(Row, Output[I*SizeOf(TRow)], SizeOf(TRow));
  end;
  TFile.WriteAllBytes(ParamStr(3), Output);
end;

var State: TCompilerFloatState;
begin
  State := EnterCompilerFloatEnvironment;
  try
    try Run;
    except on E: Exception do begin Writeln(ErrOutput, E.Message); ExitCode := 2; end; end;
  finally LeaveCompilerFloatEnvironment(State); end;
end.
